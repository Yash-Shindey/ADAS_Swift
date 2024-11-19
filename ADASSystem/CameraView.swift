//
//  CameraView.swift
//  ADASSystem
//
//  Created by Yash Shindey on 18/11/24.
//

import SwiftUI
import AVFoundation

struct CameraView: NSViewRepresentable {
    @ObservedObject var cameraManager: CameraManager
    
    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.backgroundColor = .black
        return view
    }
    
    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.image = cameraManager.currentFrame
    }
}

class CameraPreviewView: NSView {
    var image: CIImage? {
        didSet {
            DispatchQueue.main.async {
                self.needsDisplay = true
            }
        }
    }
    
    var backgroundColor: NSColor = .black {
        didSet {
            needsDisplay = true
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let image = image else { return }
        
        let context = NSGraphicsContext.current?.cgContext
        context?.clear(bounds)
        
        // Fill background
        backgroundColor.setFill()
        dirtyRect.fill()
        
        // Calculate aspect-fit dimensions
        let imageSize = image.extent.size
        let viewSize = bounds.size
        let scale = min(viewSize.width / imageSize.width,
                       viewSize.height / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let x = (viewSize.width - scaledWidth) / 2
        let y = (viewSize.height - scaledHeight) / 2
        
        // Create CGImage
        let context2 = CIContext()
        if let cgImage = context2.createCGImage(image, from: image.extent) {
            // Draw the image
            context?.draw(cgImage, in: NSRect(x: x, y: y,
                                            width: scaledWidth,
                                            height: scaledHeight))
        }
    }
}
