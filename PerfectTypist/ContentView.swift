/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's main view.
*/

import SwiftUI
import ScreenCaptureKit
import OSLog
import Combine

struct ContentView: View {
    
    @State var userStopped = false
    @State var disableInput = false
    @State var isScreenRecordingUnauthorized = false
	@State var isKeyCaptureUnauthorized = false

    @StateObject var screenRecorder = ScreenRecorder()
    
    var body: some View {
        HSplitView {
            ConfigurationView(screenRecorder: screenRecorder, userStopped: $userStopped)
                .frame(minWidth: 280, maxWidth: 280)
                .disabled(disableInput)
            screenRecorder.capturePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(screenRecorder.contentSize, contentMode: .fit)
                .padding(8)
                .overlay {
                    if userStopped {
                        Image(systemName: "nosign")
                            .font(.system(size: 250, weight: .bold))
                            .foregroundColor(Color(white: 0.3, opacity: 1.0))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(white: 0.0, opacity: 0.5))
                    }
                }
        }
		.overlay {
			VStack(spacing: 0) {
				Spacer()
				if isScreenRecordingUnauthorized {
					VStack {
						Text("No screen recording permission.")
							.font(.largeTitle)
							.padding(.top)
						Text("Open System Settings and go to Privacy & Security > [Screen Recording](x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture) to grant permission.")
							.font(.title2)
							.padding(.bottom)
					}
					.frame(maxWidth: .infinity)
					.background(.red)
				}
				if isKeyCaptureUnauthorized {
					VStack {
						Text("No accessibility permission.")
							.font(.largeTitle)
							.padding(.top)
						Text("Open System Settings and go to Privacy & Security > [Accessibility](x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility) to grant permission.")
							.font(.title2)
							.padding(.bottom)
					}
					.frame(maxWidth: .infinity)
					.background(.orange)
				}
			}
		}
        .navigationTitle("Screen Capture Sample")
        .onAppear {
            Task {
				await screenRecorder.monitorAvailableContent()

				let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
				let processTrusted: Bool = AXIsProcessTrustedWithOptions(options as CFDictionary)
				isKeyCaptureUnauthorized = !processTrusted

                if await screenRecorder.canRecord {
                    // DON'T START RECORDING AUTOMATICALLY. If we do, need to fix userRecording too.
                   // await screenRecorder.start()
                } else {
                    isScreenRecordingUnauthorized = true
                    disableInput = true
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
