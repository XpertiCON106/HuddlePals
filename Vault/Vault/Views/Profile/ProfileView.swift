import SwiftUI

struct ProfileView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: ProfileViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ProfileContent(viewModel: viewModel) {
                    router.resetAll()
                }
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("Profile")
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = ProfileViewModel(deps: deps) }
        }
    }
}

private struct ProfileContent: View {
    @Bindable var viewModel: ProfileViewModel
    let onSignOut: () -> Void

    var body: some View {
        List {
            profileSection
            accountSection
            debugSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private var profileSection: some View {
        Section("Your profile") {
            HStack(spacing: 14) {
                AvatarView(
                    name: viewModel.displayName.isEmpty ? "?" : viewModel.displayName,
                    colorHex: viewModel.selectedColorHex,
                    size: 52
                )
                TextField("Display name", text: $viewModel.displayName)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
            }
            .listRowBackground(Theme.surface)

            HStack(spacing: 10) {
                ForEach(AvatarPalette.hexes, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 26, height: 26)
                        .overlay {
                            if hex == viewModel.selectedColorHex {
                                Circle().strokeBorder(.white, lineWidth: 2)
                            }
                        }
                        .onTapGesture {
                            viewModel.selectedColorHex = hex
                            Haptics.light()
                        }
                }
            }
            .listRowBackground(Theme.surface)

            Button {
                Task { await viewModel.saveProfile() }
            } label: {
                HStack {
                    Text("Save changes")
                    if let status = viewModel.statusMessage {
                        Spacer()
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .disabled(viewModel.isWorking)
            .listRowBackground(Theme.surface)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Button(role: .destructive) {
                Task {
                    await viewModel.signOut()
                    onSignOut()
                }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .listRowBackground(Theme.surface)
        }
    }

    private var debugSection: some View {
        Section {
            Toggle(isOn: $viewModel.simulateNotPostedToday) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulate: I haven't posted today")
                    Text("Forces the reciprocity gate shut to demo the locked state.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            Button {
                Task { await viewModel.advanceMockDay() }
            } label: {
                HStack {
                    Label("Advance mock day by 1", systemImage: "calendar.badge.plus")
                    Spacer()
                    Text("+\(viewModel.mockDayOffset)d")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(viewModel.mockDayOffset > 0 ? Theme.accent : Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)

            Button {
                Task { await viewModel.regenerateSeedData() }
            } label: {
                Label("Regenerate seed data", systemImage: "arrow.clockwise.circle")
            }
            .disabled(viewModel.isWorking)
            .listRowBackground(Theme.surface)
        } header: {
            Label("DEBUG", systemImage: "wrench.and.screwdriver")
                .foregroundStyle(Theme.accent)
        } footer: {
            Text("Demo tools — none of this ships. Advancing the day shifts the injected clock so streak math can be exercised without waiting for midnight.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(viewModel.appVersion)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        }
    }
}
