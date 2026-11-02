import Foundation
import Testing
import SceneKit
@testable import AlpineRide

struct RideMotionTests {
    @Test @MainActor func rendersLakeWorld() throws {
        let world = AlpineRideScene()
        world.move(distance: 180)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = world.scene
        renderer.pointOfView = world.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1280, height: 720), antialiasingMode: .multisampling2X)
        let data = try #require(image.pngData())
        #expect(data.count > 10_000)
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alpine-ride-preview.png")
        try data.write(to: output)
        print("RIDE_PREVIEW_PATH=\(output.path)")
    }

    @Test func decodesSignedLittleEndianPowerWithoutOptionalFields() {
        #expect(RideMotion.decodePower(Data([0, 0, 250, 0])) == 250)
        #expect(RideMotion.decodePower(Data([0, 0, 0xF6, 0xFF])) == -10)
        #expect(RideMotion.decodePower(Data([0xFF, 0, 0x2C, 1, 99, 88])) == 300)
        #expect(RideMotion.decodePower(Data([0, 0, 250])) == nil)
        #expect(RideMotion.decodePower(Data()) == nil)
    }

    @Test func visualMotionStopsWithoutPositivePowerAndIsBounded() {
        #expect(RideMotion.speed(watts: 0) == 0)
        #expect(RideMotion.speed(watts: -20) == 0)
        #expect(RideMotion.speed(watts: 250) > RideMotion.speed(watts: 100))
        #expect(RideMotion.speed(watts: 32767) <= 18)
    }
}
