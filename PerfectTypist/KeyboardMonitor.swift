//
//  KeyboardMonitor.swift
//  PerfectTypist
//

import Cocoa
import Carbon.HIToolbox.Events
import AVFoundation
import VideoToolbox

private struct Keystroke {
    let timestamp: TimeInterval // The time when the event occurred in seconds since system startup.
    let characters: String      // Should be a one-character string
}

class KeyboardMonitor {
    internal init(circularBuffer: CircularBuffer<CMSampleBuffer>, compressionSession: VTCompressionSession) {
        self.circularBuffer = circularBuffer
        self.compressionSession = compressionSession
    }
    
    private let circularBuffer: CircularBuffer<CMSampleBuffer>
    private let compressionSession: VTCompressionSession

    private var storedKeystrokes = [Keystroke]()

    func activateMonitor(_ enabled: Bool) {
        
        guard enabled else {
            eventMonitors.forEach { monitor in
				if let monitor {
					NSEvent.removeMonitor(monitor)
				}
			}
            eventMonitors = []
            return
        }
        guard eventMonitors.isEmpty else { return } // do nothing if already monitoring
                
        // kAXTrustedCheckOptionPrompt's value indicates whether the user will be informed if the current process is untrusted.
        // We set this to be false because we are doing our own prompting, and not worrying if it is not trusted.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
        let processTrusted: Bool = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        guard processTrusted else { 
            print("NOT ACTIVATING, PROCESS IS NOT TRUSTED")
            return
        }
        
        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.monitorKeystroke(event: event, isLocal: true)
            return event // return unmodified event
        })
        
        // Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access (see AXIsProcessTrusted in AXUIElement.h). Note that your handler will not be called for events that are sent to your own application.
        // To enable AXIsProcessTrusted() in your app you need to go to your macOS system preferences, open Security and Privacy, click on Accessibility, click on the plus sign to add your app to the list off apps that can control your computer. You might need to click at the padlock and type your password to unlock your settings.
        
        eventMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.monitorKeystroke(event: event, isLocal: false)
        })
        
        // Also, monitor mouse events. When there is a mouse event, we reset the monitoring so that backspace has no more effect.
        // We just need to monitor mouse down events - not really likely to be typing while the mouse is held down or dragged, right?
        let mouseEventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: mouseEventMask) { [weak self] event in
            self?.resetKeystrokeMonitoring()
            return event // return unmodified event
        })
        
        eventMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: mouseEventMask) { [weak self] event in
            self?.resetKeystrokeMonitoring()
        })
    }
    

    
    // MARK: Key capturing
    
    private var eventMonitors: [Any?] = []
    
    /// It would be great to have some function to know whether a keystroke results in a real, printable character. Use this instead.
    private let invalidatingKeyCodes: Set<Int> = [
        // Function keys
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        // Arrow & Navigation
        kVK_DownArrow, kVK_End, kVK_Home, kVK_LeftArrow, kVK_PageDown, kVK_PageUp, kVK_RightArrow, kVK_UpArrow,
        // Other keys that probably mess up current line of text editing
        kVK_Escape, kVK_ForwardDelete, kVK_Return, kVK_Tab]
    
    private func monitorKeystroke(event: NSEvent, isLocal: Bool) {
        guard event.type == .keyDown else { return }
        let timestamp = event.timestamp // The time when the event occurred in seconds since system startup.
        if event.keyCode == kVK_Delete &&  event.modifierFlags.intersection([.shift, .control, .option, .command]) == []  {
            // Take us back in time !!!
            if let lastStoredKeystroke: Keystroke = storedKeystrokes.popLast() {
                compressionSession.flush()
                backupVideo(keystroke: lastStoredKeystroke)
            }
            // Might have hit ⬅️ when the buffer is empty, in which case we can't do any repairs, so ignore
        } else if invalidatingKeyCodes.contains(Int(event.keyCode)) || event.modifierFlags.contains([.command, .control]) {
            resetKeystrokeMonitoring()       // Clear out history
            print("——————————————————————")
        } else if let characters = event.characters {
            compressionSession.flush() // Let's see if this cleans up things
            print("⏺ “\(characters)” @ \(timestamp) -> \(circularBuffer.writeIndex)")
            storedKeystrokes.append(Keystroke(timestamp: timestamp, characters: characters))            // I don't think I need to worry about the video recording here
        }
    }
    
    /// Clear out the history when there is a mouse event or a character being typed/entered that might mess up the backspace history
    private func resetKeystrokeMonitoring() {
        storedKeystrokes = []
    }

    private func backupVideo(keystroke: Keystroke) {
        print("⬅ Back up video to just before \(keystroke.timestamp) when “\(keystroke.characters)” was typed")
        
        let readIndexRange: Range<Int> = circularBuffer.readIndexRange
        for readIndex in readIndexRange.reversed() {
            guard let sampleBuffer = circularBuffer[readIndex] else {
                print("😡 no sample buffer at \(readIndex)")
                break
            }
            let timestamp: TimeInterval = sampleBuffer.presentationTime
            let frameIsAfterBackspace: Bool =  keystroke.timestamp < timestamp
            if frameIsAfterBackspace {
                circularBuffer[readIndex] = nil // clear out frame created after the deleted character was typed
            } else {
                circularBuffer.writeIndex = readIndex + 1   // keep this frame, so start recording after that.
                print("     \(readIndex): \(keystroke.timestamp) !< \(timestamp) ; new index \(circularBuffer.writeIndex) ")
                break
            }
        }
    }
}
