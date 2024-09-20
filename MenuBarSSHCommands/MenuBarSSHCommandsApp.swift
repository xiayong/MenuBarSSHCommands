//
//  MenuBarSSHCommandsApp.swift
//  MenuBarSSHCommands
//
//  Created by Dieskim on 7/18/23.
//

import SwiftUI
import Combine
import Foundation
import ServiceManagement

class ButtonContainerStore: ObservableObject {
    @Published var buttonContainer: [ButtonContainer] = []
    let jsonFileName = "MenuBarSSHCommandsData"
    var terminal: String = "Terminal"
    var userFileURL: URL?
    private var fileMonitor: FileMonitor?
    
    init() {
        do {
            setupFileURLs()
            loadButtonContainer()
            startMonitoringFileChanges()
            try SMAppService.mainApp.register()
        } catch {
            print("Error \(error)")
        }
    }
    
    private func setupFileURLs() {
        let fileManager = FileManager.default
        let userDirectory = fileManager.homeDirectoryForCurrentUser
        userFileURL = userDirectory.appendingPathComponent(".mbsc.json")
        
        let bundleFileURL = Bundle.main.url(forResource: jsonFileName, withExtension: "json")
        guard let bundleFileURL = bundleFileURL else { return }

        if !fileManager.fileExists(atPath: userFileURL!.path) {
            do {
                try fileManager.copyItem(at: bundleFileURL, to: userFileURL!)
            } catch {
                print("Error copying file: \(error)")
            }
        }
    }

    func loadButtonContainer() {
        guard let fileURL = userFileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return
        }

        let decoder = JSONDecoder()
        if let jsonData = try? JSONSerialization.jsonObject(with: data, options: []),
           let json = jsonData as? [String: Any],
           let terminal = json["terminal"] as? String,
           let data = json["data"] as? [[String: Any]] {
            self.terminal = terminal
            if let loadedButtonContainer = try? decoder.decode([ButtonContainer].self, from: JSONSerialization.data(withJSONObject: data, options: [])) {
                buttonContainer = loadedButtonContainer
            }
        }
    }
    
    private func startMonitoringFileChanges() {
        guard let fileURL = userFileURL else { return }
        fileMonitor = FileMonitor(fileURL: fileURL)
        fileMonitor?.startMonitoring { [weak self] in
            DispatchQueue.main.async {
                self?.loadButtonContainer()
            }
        }
    }
}

class FileMonitor {
    private var fileURL: URL?
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring(changeHandler: @escaping () -> Void) {
        guard let fileURL = fileURL else { return }

        fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }

        let queue = DispatchQueue.global(qos: .utility)
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)

        source?.setEventHandler {
            changeHandler()
        }

        source?.setCancelHandler { [weak self] in
            self?.stopMonitoring()
        }

        source?.resume()
    }

    private func stopMonitoring() {
        source?.cancel()
        source = nil
        close(fileDescriptor)
        fileDescriptor = -1
    }
}


@main
struct MenuBarSSHCommandsApp: App {
    
    @StateObject private var buttonContainerStore = ButtonContainerStore()
    var body: some Scene {
        MenuBarExtra{
            ForEach(buttonContainerStore.buttonContainer.indices, id: \.self) { index in
                if let actions = buttonContainerStore.buttonContainer[index].actions {
                    ForEach(actions) { action in
                        Button(action.name, action: {
                            executeCommand(action.command)
                        })
                    }
                } else if let sections = buttonContainerStore.buttonContainer[index].sections {
                    ForEach(sections) { section in
                        Menu(section.name) {
                            ForEach(section.actions) { action in
                                Button(action.name, action: {
                                    executeCommand(action.command)
                                })
                            }
                        }
                    }
                }
            }
            Divider()
            Button(NSLocalizedString("Edit", comment: "Edit Commands"), action: openJSONFile)
            //Button("Reload", action: buttonContainerStore.loadButtonContainer)
            Button(NSLocalizedString("Quit", comment: "Quit Aplication"), action: {
               NSApplication.shared.terminate(nil)
           })
        }
        label: {
        
            let image: NSImage = {
                let ratio = $0.size.height / $0.size.width
                $0.size.height = 16
                $0.size.width = 16 / ratio
                return $0
            }(NSImage(named: "Icon")!)
        
            Image(nsImage: image)
        }
    }

    private func executeCommand(_ command: String) {
        let terminal = buttonContainerStore.terminal
        var source: String
        if terminal == "iTerm" {
            source = """
            if application "\(terminal)" is running then
                tell application "\(terminal)"
                    activate
                    tell (create window with default profile)
                        delay 0.2 -- Wait for the terminal to launch
                        tell current session
                            write text "\(command)"
                        end tell
                    end tell
                end tell
            else
                tell application "\(terminal)"
                    activate
                    delay 0.5 -- Wait for the terminal to launch
                    tell current window
                        tell current session
                            write text "\(command)"
                        end tell
                    end tell
                end tell
            end if
            """
        } else {
            source = """
            tell application "\(terminal)"
                if not (running) then
                    activate
                    delay 0.3
                    do script "\(command)" in window 1
                else
                    activate
                    tell application "System Events"
                        keystroke "t" using {command down}
                    end tell
                    delay 0.3
                    tell front window
                        do script "\(command)" in selected tab
                    end tell
                end if
            end tell
            """
        }




        DispatchQueue.global(qos: .background).async {
            if let script = NSAppleScript(source: source) {
                var errorInfo: NSDictionary?
                script.executeAndReturnError(&errorInfo)
                if let error = errorInfo {
                    print("Error executing AppleScript: \(error)")
                }
            } else {
                print("Failed to create AppleScript instance.")
            }
        }
    }


    
    private func openJSONFile() {
        guard let fileUrl = buttonContainerStore.userFileURL else {
            return
        }
        
        NSWorkspace.shared.open(fileUrl)
    }

}

struct Section: Identifiable, Equatable, Decodable {
    var id: UUID { UUID() }
    let name: String
    var actions: [ButtonAction]
}

struct ButtonAction: Identifiable, Equatable, Decodable {
    var id = UUID()
    let name: String
    let command: String
}

struct ButtonContainer: Identifiable, Decodable {
    let id = UUID()
    var actions: [ButtonAction]?
    var sections: [Section]?

    enum CodingKeys: String, CodingKey {
        case actions, action
        case section
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decodeIfPresent([ButtonAction].self, forKey: .actions) ?? container.decodeIfPresent([ButtonAction].self, forKey: .action)
        sections = try? container.decode([Section].self, forKey: .section)
    }
}
