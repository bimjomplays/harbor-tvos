import SwiftUI

struct HelloView: View {
    private var build: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.086, green: 0.106, blue: 0.149), Color(red: 0.031, green: 0.035, blue: 0.039)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 140))
                Text("Harbor")
                    .font(.system(size: 76, weight: .semibold))
                Text("Build \(build)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("build-label")
            }
        }
    }
}
