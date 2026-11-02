import SwiftUI

@main
struct AlpineRideApp: App {
    @State private var showRide = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.06, green: 0.14, blue: 0.16).ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 80)).foregroundStyle(.orange)
                    Text("Alpine Ride").font(.largeTitle.bold())
                    Text("Your bike. Your world.").font(.title3)
                    Text("Explore a mountain lake, or connect your indoor trainer and pedal through it.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Enter Alpine Lake") { showRide = true }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                    Text("Early prototype • No account or subscription")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth: 540)
            }
            .preferredColorScheme(.dark)
            .fullScreenCover(isPresented: $showRide) { RideWorldView() }
        }
    }
}
