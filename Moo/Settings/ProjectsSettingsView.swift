//
//  ProjectsSettingsView.swift
//  Moo
//
//  Deliberately small. The sidebar's visibility is a View menu item, its
//  shortcut is fixed at cmd+B, its width is whatever you last dragged it to,
//  and the cmd+digit binding lives in Keyboard. None of those are options.
//
//  What is left is what a project actually is: the list, and how much of it a
//  row shows.
//

import AppKit
import SwiftUI

struct ProjectsSettingsView: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var profiles: ProfileStore

    @AppStorage(ProjectSidebarDefaults.showsStatus) private var showsStatus = true
    @AppStorage(ProjectSidebarDefaults.showsBranch) private var showsBranch = true
    @AppStorage(ProjectSidebarDefaults.showsPath) private var showsPath = true
    @AppStorage(ProjectSidebarDefaults.showsAccent) private var showsAccent = true

    @State private var selection: Project.ID?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Row Contents") {
                Text("The project name is always shown. A project can override any of these for itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Status", isOn: $showsStatus)
                Toggle("Git branch", isOn: $showsBranch)
                Toggle("Directory path", isOn: $showsPath)
                Toggle("Accent color", isOn: $showsAccent)
            }

            Section("Projects") {
                projectTable
                HStack {
                    Button("Remove", action: removeSelected)
                        .disabled(selection == nil)
                    Spacer()
                    Text("New projects are created with ⌘N.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let project = selectedProject {
                    projectDetail(project)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            "Could Not Change Projects",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var projectTable: some View {
        Table(projects.projects, selection: $selection) {
            TableColumn("Name") { project in
                Text(project.displayName(
                    directory: ProjectRuntime.shared.currentDirectory(for: project.id)
                ))
            }
            TableColumn("Location") { project in
                // Live, not stored: a project is a label and follows its
                // terminals' working directory.
                let directory = ProjectRuntime.shared.currentDirectory(for: project.id)
                Text(directory?.abbreviatedPath ?? "Not running")
                    .foregroundStyle(directory == nil ? .secondary : .primary)
            }
        }
        .frame(minHeight: 140)
    }

    private var selectedProject: Project? {
        projects.project(withID: selection)
    }

    @ViewBuilder
    private func projectDetail(_ project: Project) -> some View {
        LabeledContent("Name") {
            TextField("Name", text: nameBinding(for: project))
                .textFieldStyle(.roundedBorder)
        }

        ColorPicker("Accent", selection: accentBinding(for: project), supportsOpacity: false)

        overridePicker("Status", for: project, keyPath: \.showsStatus, global: showsStatus)
        overridePicker("Git branch", for: project, keyPath: \.showsBranch, global: showsBranch)
        overridePicker("Directory path", for: project, keyPath: \.showsPath, global: showsPath)
        overridePicker("Accent color", for: project, keyPath: \.showsAccent, global: showsAccent)
    }

    /// Three-state: follow the app-wide default, force on, or force off.
    private func overridePicker(
        _ title: String,
        for project: Project,
        keyPath: WritableKeyPath<ProjectRowOptions, Bool?>,
        global: Bool
    ) -> some View {
        Picker(title, selection: Binding<Int>(
            get: {
                switch project.rowOptions[keyPath: keyPath] {
                case .none: return 0
                case .some(true): return 1
                case .some(false): return 2
                }
            },
            set: { newValue in
                var updated = project
                updated.rowOptions[keyPath: keyPath] = newValue == 0 ? nil : (newValue == 1)
                save(updated)
            }
        )) {
            Text("Default (\(global ? "shown" : "hidden"))").tag(0)
            Text("Show").tag(1)
            Text("Hide").tag(2)
        }
    }

    private func nameBinding(for project: Project) -> Binding<String> {
        Binding(
            get: {
                project.displayName(
                    directory: ProjectRuntime.shared.currentDirectory(for: project.id)
                )
            },
            set: { newValue in
                // An empty field is a transient editing state, not a rename.
                guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                var updated = project
                updated.name = newValue
                // An explicit name stops the row following the directory.
                updated.isAutoNamed = false
                save(updated)
            }
        )
    }

    private func accentBinding(for project: Project) -> Binding<Color> {
        Binding(
            get: { project.accentColor?.swiftUIColor ?? .accentColor },
            set: { newValue in
                var updated = project
                updated.accentColor = ProfileColor(swiftUIColor: newValue)
                save(updated)
            }
        )
    }

    private func save(_ project: Project) {
        do {
            try projects.update(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        do {
            try projects.delete(id)
            ProjectRuntime.shared.discardSession(for: id)
            selection = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Projects Settings") {
    ProjectsSettingsView()
        .environmentObject(SettingsPreviewData.projects)
        .environmentObject(SettingsPreviewData.profiles)
        .frame(width: 820, height: 560)
}
