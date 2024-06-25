//
//  CircularBuffer.swift
//  PerfectTypist
//

import Foundation

// Based on this article: https://engineering.giphy.com/doing-it-live-at-giphy-with-avfoundation/
class CircularBuffer<T> {
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array<T?>(repeating: nil, count: capacity)
    }
    
    private var buffer = [T?]()
    private let capacity : Int
    var writeIndex : Int = 0 // monotonic increasing (unless it's edited), the index (modulo capacity) where *next* sample will go
    
    /*
     * Appends a new value to the buffer. Returns whatever it displaced, so it can be spooled out.
     */
    func write(_ newElement: T) -> T? {
        // Calculate the index to write to, account for wrap-around
        let i = self.writeIndex % self.capacity
        
        // Write the new value
        // print("Writing to array index \(i) sample number \(self.writeIndex), capacity = \(self.capacity)")
        let displacedElement: T? = self.buffer[i]
        self.buffer[i] = newElement
        
        // Increment write index
        self.writeIndex += 1
        return displacedElement
    }
    /*
     Warning: For simplicity, the example above is not thread-safe. To support concurrency, you should use a serial dispatch queue or semaphore to control write access.
     
     The main trick is that the writeIndex needs to wrap back to the beginning when the buffer is full. We can use the mod operator to handle that. The new element will then overwrite any data that was previously there.
     
     */    
    
    /*
     * Returns a copy of the current data in the the ring buffer, in the order that it
     * was written, as a sequential array.
     */
    func readAll() -> [T] {
        if self.writeIndex <= self.capacity {
            // If we haven't made a full wraparound yet, return data from index 0..<writeIndex
            return Array(self.buffer[0..<self.writeIndex].compactMap { $0 as T? })
        } else {
            // Otherwise, if we have wrapped around, we need to start from writeIndex (accounting
            // for wrap-around).
            var orderedArray = [T?]()
            
            for i in 0..<self.capacity {
                let readIndex = (self.writeIndex + i) % self.capacity
                orderedArray.append(self.buffer[readIndex])
            }
            
            return orderedArray.compactMap { $0 as T? }
        }
    }
    
    // Range of indexes that have data. An open range meaning we don't include the last value, since writeIndex is the *next* spot.
    var readIndexRange: Range<Int> {
        if self.writeIndex <= self.capacity {
            return 0 ..< self.writeIndex
        } else {
            return self.writeIndex - self.capacity ..< self.writeIndex
        }

    }
    
    subscript(index: Int) -> T? {
        get {
            let i = index % self.capacity
            return buffer[i]
        }
        set(newValue) {
            let i = index % self.capacity
            buffer[i] = newValue
        }
    }

    
    func finishWriting() {
        buffer.removeAll(keepingCapacity: true)
    }
}

