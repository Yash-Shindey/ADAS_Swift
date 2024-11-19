//
//  ObjectDetection.swift
//  ADASSystem
//
//  Created by Yash Shindey on 19/11/24.
//

import Vision
import CoreML
import SwiftUI

struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
}

class ObjectDetector: ObservableObject {
    private var model: VNCoreMLModel?
    private let labels = ["bus", "truck", "pedestrian", "car"]
    private let confidenceThreshold: Float = 0.5
    
    init() {
        setupModel()
    }
    
    private func setupModel() {
        do {
            guard let modelURL = Bundle.main.url(forResource: "ADAS_Safety_System1", withExtension: "mlmodelc") else {
                print("Failed to find model file")
                return
            }
            
            let config = MLModelConfiguration()
            config.computeUnits = .all // Use Neural Engine when available
            
            model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: config))
        } catch {
            print("Failed to load model: \(error)")
        }
    }
    
    func detect(in image: CIImage, completion: @escaping ([Detection]) -> Void) {
        guard let model = model else {
            completion([])
            return
        }
        
        let request = VNCoreMLRequest(model: model) { request, error in
            guard error == nil,
                  let results = request.results as? [VNRecognizedObjectObservation] else {
                completion([])
                return
            }
            
            let detections = results
                .filter { $0.confidence >= self.confidenceThreshold }
                .compactMap { observation -> Detection? in
                    guard let label = observation.labels.first?.identifier else { return nil }
                    return Detection(
                        label: label,
                        confidence: observation.confidence,
                        boundingBox: observation.boundingBox
                    )
                }
            
            DispatchQueue.main.async {
                completion(detections)
            }
        }
        
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        try? handler.perform([request])
    }
}
