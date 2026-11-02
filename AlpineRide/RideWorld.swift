import SwiftUI
import SceneKit
import CoreBluetooth
import Combine

// A local prototype: reads power only. It never writes trainer resistance or logs workouts.
@MainActor @Observable
final class RideTrainer: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var devices: [CBPeripheral] = []
    var status = "Choose Find trainer to connect your KICKR."
    var watts: Int?
    var lastSample: Date?
    var connected = false
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var timeout: Task<Void, Never>?
    private let service = CBUUID(string: "1818")
    private let measurement = CBUUID(string: "2A63")

    func scan() {
        disconnect()
        devices = []
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScan()
        }
    }

    private func beginScan() {
        guard central?.state == .poweredOn else {
            status = "Enable Bluetooth and allow Alpine Ride access in Settings."
            return
        }
        status = "Searching for cycling power sensors…"
        central?.scanForPeripherals(withServices: [service])
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.central?.stopScan()
            self.status = self.devices.isEmpty ? "No trainer found. Wake the KICKR, then try again." : "Select your KICKR below."
        }
    }

    func connect(_ device: CBPeripheral) {
        timeout?.cancel()
        central?.stopScan()
        peripheral = device
        device.delegate = self
        status = "Connecting to \(device.name ?? "trainer")…"
        central?.connect(device)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, !self.connected else { return }
            self.disconnect()
            self.status = "Connection timed out. Try finding the trainer again."
        }
    }

    func disconnect() {
        timeout?.cancel()
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        connected = false
        watts = nil
        lastSample = nil
        status = "Trainer disconnected."
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { beginScan() }
        else { disconnect(); status = "Bluetooth unavailable. Check Bluetooth access in Settings." }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !devices.contains(where: { $0.identifier == peripheral.identifier }) { devices.append(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        disconnect()
        status = "Could not connect. Wake the trainer and try again."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        disconnect()
        status = "Trainer connection lost. Find trainer to reconnect."
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let found = peripheral.services?.first(where: { $0.uuid == service }) else {
            disconnect(); status = "Cycling power service unavailable."; return
        }
        peripheral.discoverCharacteristics([measurement], for: found)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let found = service.characteristics?.first(where: { $0.uuid == measurement }),
              found.properties.contains(.notify) else {
            disconnect(); status = "This device does not expose cycling power notifications."; return
        }
        peripheral.setNotifyValue(true, for: found)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, characteristic.isNotifying else {
            disconnect(); status = "Power notifications failed. Try connecting again."; return
        }
        timeout?.cancel()
        connected = true
        devices = []
        status = "Connected. Pedal to move through the world."
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == measurement,
              error == nil, let data = characteristic.value, let power = RideMotion.decodePower(data) else { return }
        watts = power
        lastSample = Date()
    }
}

enum RideMotion {
    static func decodePower(_ data: Data) -> Int? {
        let bytes = Array(data)
        guard bytes.count >= 4 else { return nil }
        return Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8))
    }

    // Deliberately approximate visual speed, not a calibrated cycling physics model.
    static func speed(watts: Int) -> Double {
        guard watts > 0 else { return 0 }
        return min(18, pow(Double(watts) / 0.3, 1.0 / 3.0))
    }
}

@MainActor
final class AlpineRideScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let rider = SCNNode()
    private let scenery = SCNNode()
    private var materials: [UIColor: SCNMaterial] = [:]
    private let radius: Float = 360
    let lapLength = Double.pi * 720

    init() {
        scene.background.contents = UIColor(red: 0.57, green: 0.78, blue: 0.87, alpha: 1)
        scene.fogColor = UIColor(red: 0.62, green: 0.79, blue: 0.85, alpha: 1)
        scene.fogStartDistance = 450
        scene.fogEndDistance = 1800
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1100
        sun.eulerAngles = SCNVector3(-0.8, -0.6, 0)
        scene.rootNode.addChildNode(sun)

        add(SCNBox(width: 3500, height: 4, length: 3500, chamferRadius: 0),
            at: SCNVector3(0, -4, 0), color: UIColor(red: 0.29, green: 0.43, blue: 0.32, alpha: 1))
        let lake = SCNCylinder(radius: 325, height: 0.6)
        lake.radialSegmentCount = 96
        add(lake, at: SCNVector3(0, -1.4, 0), color: UIColor(red: 0.12, green: 0.52, blue: 0.65, alpha: 1))

        // Continuous meshes avoid overlapping road surfaces and visible seams.
        add(roadMesh(width: 13, lift: -0.2), at: SCNVector3Zero,
            color: UIColor(red: 0.41, green: 0.46, blue: 0.33, alpha: 1))
        add(roadMesh(width: 8, lift: 0), at: SCNVector3Zero,
            color: UIColor(red: 0.24, green: 0.29, blue: 0.30, alpha: 1))
        for index in stride(from: 0, to: 720, by: 4) {
            let angle = Float(index) / 720 * 2 * .pi
            let stripe = add(SCNBox(width: 0.14, height: 0.02, length: 2, chamferRadius: 0),
                             at: point(angle, lift: 0.03), color: .init(white: 0.87, alpha: 1))
            stripe.eulerAngles.y = -angle
            stripe.eulerAngles.x = -atan(6 * cos(angle * 3) / radius)
        }
        for index in 0..<180 {
            let angle = Float(index) * 2.39996
            let distance: Float = 378 + Float((index * 37) % 160)
            let height: CGFloat = CGFloat(10 + index % 13)
            let tree = SCNCone(topRadius: 0, bottomRadius: height * 0.3, height: height)
            tree.radialSegmentCount = 5
            add(tree, at: SCNVector3(cos(angle) * distance, Float(height / 2) - 1, sin(angle) * distance),
                color: UIColor(red: 0.10, green: 0.25 + CGFloat(index % 4) * 0.035, blue: 0.22, alpha: 1))
        }
        for index in 0..<24 {
            let angle = Float(index) / 24 * 2 * .pi
            let height: CGFloat = CGFloat(140 + (index * 43) % 140)
            let mountain = SCNCone(topRadius: 0, bottomRadius: 190, height: height)
            mountain.radialSegmentCount = 5
            add(mountain, at: SCNVector3(cos(angle) * 1000, Float(height / 2) - 4, sin(angle) * 1000),
                color: UIColor(red: 0.34 + CGFloat(index % 3) * 0.035, green: 0.43, blue: 0.48, alpha: 1))
            let snow = SCNCone(topRadius: 0, bottomRadius: 47.5, height: height / 4)
            snow.radialSegmentCount = 5
            add(snow, at: SCNVector3(cos(angle) * 1000, Float(height * 0.875) - 4, sin(angle) * 1000),
                color: UIColor(red: 0.87, green: 0.92, blue: 0.91, alpha: 1))
        }
        scene.rootNode.addChildNode(scenery.flattenedClone())
        // Simple rider silhouette and bicycle, facing local negative Z.
        for z: Float in [-0.65, 0.65] {
            let wheel = SCNNode(geometry: SCNTorus(ringRadius: 0.34, pipeRadius: 0.045))
            wheel.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.10, alpha: 1)
            wheel.eulerAngles.z = .pi / 2
            wheel.position = SCNVector3(0, 0.4, z)
            rider.addChildNode(wheel)
        }
        let frame = SCNNode(geometry: SCNBox(width: 0.09, height: 0.35, length: 1.1, chamferRadius: 0.06))
        frame.geometry?.firstMaterial?.diffuse.contents = UIColor.systemOrange
        frame.position = SCNVector3(0, 0.75, 0)
        rider.addChildNode(frame)
        let body = SCNNode(geometry: SCNCapsule(capRadius: 0.24, height: 0.75))
        body.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.96, green: 0.42, blue: 0.24, alpha: 1)
        body.position = SCNVector3(0, 1.3, 0)
        body.eulerAngles.x = -0.45
        rider.addChildNode(body)
        let helmet = SCNNode(geometry: SCNSphere(radius: 0.20))
        helmet.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        helmet.position = SCNVector3(0, 1.83, -0.25)
        rider.addChildNode(helmet)
        for side: Float in [-1, 1] {
            limb(from: SCNVector3(side * 0.18, 1.52, -0.1), to: SCNVector3(side * 0.32, 1.13, -0.7), radius: 0.07, color: .systemOrange)
            limb(from: SCNVector3(side * 0.14, 1.05, 0.1), to: SCNVector3(side * 0.19, 0.65, -0.15), radius: 0.10, color: .darkGray)
            limb(from: SCNVector3(side * 0.19, 0.65, -0.15), to: SCNVector3(side * 0.18, 0.35, 0.1), radius: 0.07, color: .darkGray)
        }
        limb(from: SCNVector3(-0.36, 1.1, -0.7), to: SCNVector3(0.36, 1.1, -0.7), radius: 0.04, color: .black)
        scene.rootNode.addChildNode(rider)
        camera.camera = SCNCamera()
        camera.camera?.zFar = 2200
        camera.camera?.fieldOfView = 68
        scene.rootNode.addChildNode(camera)
        move(distance: 0)
    }

    private func limb(from start: SCNVector3, to end: SCNVector3, radius: CGFloat, color: UIColor) {
        let length = sqrt(pow(end.x - start.x, 2) + pow(end.y - start.y, 2) + pow(end.z - start.z, 2))
        let node = SCNNode(geometry: SCNCylinder(radius: radius, height: CGFloat(length)))
        node.geometry?.firstMaterial?.diffuse.contents = color
        node.position = SCNVector3((start.x + end.x) / 2, (start.y + end.y) / 2, (start.z + end.z) / 2)
        node.look(at: end, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 1, 0))
        rider.addChildNode(node)
    }

    private func roadMesh(width: Float, lift: Float) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        for index in 0...720 {
            let angle = Float(index) / 720 * 2 * .pi
            for offset in [-width / 2, width / 2] {
                vertices.append(SCNVector3(cos(angle) * (radius + offset), point(angle).y + lift, sin(angle) * (radius + offset)))
                normals.append(SCNVector3(0, 1, 0))
            }
            if index < 720 {
                let a = Int32(index * 2)
                indices += [a, a + 2, a + 1, a + 1, a + 2, a + 3]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    private func point(_ angle: Float, lift: Float = 0) -> SCNVector3 {
        SCNVector3(cos(angle) * radius, 2 + 2 * sin(angle * 3) + lift, sin(angle) * radius)
    }

    @discardableResult
    private func add(_ shape: SCNGeometry, at position: SCNVector3, color: UIColor) -> SCNNode {
        let material: SCNMaterial
        if let cached = materials[color] { material = cached }
        else {
            material = SCNMaterial()
            material.diffuse.contents = color
            materials[color] = material
        }
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        node.position = position
        scenery.addChildNode(node)
        return node
    }

    func move(distance: Double) {
        let angle = Float(distance.truncatingRemainder(dividingBy: lapLength)) / radius
        rider.position = point(angle, lift: 0.2)
        rider.eulerAngles.y = .pi - angle
        camera.position = point(angle - 0.025, lift: 4)
        camera.look(at: point(angle + 0.025, lift: 1.5))
    }
}

struct RideWorldView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var trainer = RideTrainer()
    @State private var world = AlpineRideScene()
    @State private var preview = false
    @State private var running = false
    @State private var distance = 0.0
    @State private var elapsed = 0.0
    @State private var showSetup = true
    @State private var previousIdleSetting = false
    @State private var previousFrame = Date()
    private let clock = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    private var livePower: Int? {
        guard trainer.connected, let last = trainer.lastSample, Date().timeIntervalSince(last) < 3 else { return nil }
        return trainer.watts
    }

    var body: some View {
        ZStack {
            SceneView(scene: world.scene, pointOfView: world.camera, preferredFramesPerSecond: 30,
                      antialiasingMode: .multisampling2X)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").padding(12) }
                        .accessibilityLabel("Close ride")
                    Spacer()
                    VStack(spacing: 3) {
                        Text("ALPINE LAKE").font(.headline).tracking(3)
                        Text(preview ? "SCENERY PREVIEW" : "LIVE POWER • PROTOTYPE").font(.caption2.bold())
                    }
                    Spacer()
                    Button { running = false; showSetup = true } label: { Image(systemName: "gearshape.fill").padding(12) }
                        .accessibilityLabel("Trainer and TV setup")
                }
                .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 24) {
                    metric(preview ? "DEMO" : livePower.map { "\($0)" } ?? "…", "WATTS")
                    metric(String(format: "%.1f", distance / 1609.344), "MILES")
                    metric(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60), "TIME")
                }
                .padding(14).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
                Spacer()
                if !preview && livePower == nil {
                    Text(trainer.connected ? "Waiting for power from your trainer" : "Connect your KICKR or explore the preview")
                        .font(.subheadline.bold()).padding(12).background(.black.opacity(0.65), in: Capsule())
                }
                Button(running ? "Pause ride" : "Resume ride") { running.toggle() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(!preview && !trainer.connected)
                Text("Prototype • Resistance stays under Garmin/manual control • Ride is not saved")
                    .font(.caption2).multilineTextAlignment(.center)
                    .padding(8).background(.black.opacity(0.65), in: Capsule())
            }.padding().foregroundStyle(.white)
        }
        .sheet(isPresented: $showSetup) { setup }
        .onAppear {
            previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            trainer.disconnect()
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { running = false }
        }
        .onReceive(clock) { now in
            let dt = min(0.1, max(0, now.timeIntervalSince(previousFrame)))
            previousFrame = now
            guard running, scenePhase == .active, !showSetup else { return }
            guard preview || livePower != nil else { return }
            elapsed += dt
            distance += (preview ? 9 : RideMotion.speed(watts: livePower ?? 0)) * dt
            world.move(distance: distance)
        }
    }

    private func metric(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title2, design: .rounded).bold()).monospacedDigit()
            Text(title).font(.caption2.bold()).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func start(preview: Bool) {
        self.preview = preview
        distance = 0
        elapsed = 0
        world.move(distance: 0)
        if preview { trainer.disconnect() }
        showSetup = false
        running = true
    }

    private var setup: some View {
        NavigationStack {
            List {
                Section {
                    Text("A winding lake loop, pine forests, and mountain peaks. Pedal to move, or explore the scenery first.")
                    Button("Explore scenery preview") { start(preview: true) }
                } header: { Text("Alpine Lake") }
                Section("Your KICKR") {
                    Text(trainer.status)
                    Button("Find trainer") { trainer.scan() }
                    ForEach(trainer.devices, id: \.identifier) { device in
                        Button(device.name ?? "Cycling power sensor") { trainer.connect(device) }
                    }
                    if trainer.connected {
                        Button("Start ride with live power") { start(preview: false) }
                        Button("Disconnect trainer") { trainer.disconnect() }
                    }
                    Text("This prototype reads power only. Use your Edge 840 for resistance and recording. Hills do not change trainer resistance yet. Virtual distance is approximate and this session is not saved.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Put the world on your TV") {
                    Text("On a compatible Roku, enable Settings → Apple AirPlay and HomeKit → AirPlay. Connect your iPhone and TV to the same Wi-Fi, then open iPhone Control Center → Screen Mirroring and choose your TV.")
                    Text("Rotate your phone sideways for a wider view. If your TV does not appear, check its model for AirPlay support. Ordinary Roku screen mirroring is not the iPhone connection method.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Alpine Ride")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSetup = false } } }
        }
    }
}
