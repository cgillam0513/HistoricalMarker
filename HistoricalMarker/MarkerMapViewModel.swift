import Foundation
import MapKit
import CoreLocation
import SwiftUI
import Combine

struct HistoricalMarker: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let text: String
    let coordinate: CLLocationCoordinate2D
    let imageName: String?

    static func == (lhs: HistoricalMarker, rhs: HistoricalMarker) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - JSON Decoding Structures
struct MarkerJSON: Decodable {
    let id: String
    let title: String
    let description: String
    let dateInstalled: String?
    let coordinates: Coordinates
    let address: Address
    let images: [String]
    let source: [Source]
    let type: String
    let tags: [String]
    let confidence: Double
    
    struct Coordinates: Decodable {
        let latitude: Double?
        let longitude: Double?
    }
    
    struct Address: Decodable {
        let city: String
        let county: String
        let state: String
    }
    
    struct Source: Decodable {
        let name: String
        let url: String
        let sourceId: String
        
        enum CodingKeys: String, CodingKey {
            case name
            case url
            case sourceId = "source_id"
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id, title, description
        case dateInstalled = "date_installed"
        case coordinates, address, images, source, type, tags, confidence
    }
    
    func toHistoricalMarker() -> HistoricalMarker? {
        guard let latitude = coordinates.latitude,
              let longitude = coordinates.longitude else {
            return nil
        }
        
        let subtitle = address.city.isEmpty ? address.county : "\(address.city), \(address.county)"
        
        return HistoricalMarker(
            title: title,
            subtitle: subtitle,
            text: description,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            imageName: images.first
        )
    }
}

@MainActor
final class MarkerMapViewModel: NSObject, ObservableObject {
    // Map state
    @Published var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    ))

    // Data
    @Published var markers: [HistoricalMarker] = []

    // Settings
    @Published var autoReadEnabled: Bool = true
    @Published var playOverAudio: Bool = true

    // Proximity
    @Published var nearbyMarker: HistoricalMarker? = nil
    var onProximityMarker: ((HistoricalMarker) -> Void)?

    // Location
    private let locationManager = CLLocationManager()
    private var lastAnnouncedMarkerIDs: Set<UUID> = []

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 25 // meters
    }

    func requestLocationAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    func loadSampleMarkers() {
        guard markers.isEmpty else { return }
        
        // Try to load from JSON file
        guard let url = Bundle.main.url(forResource: "tx_historical_markers", withExtension: "json") else {
            print("Error: Could not find tx_historical_markers.json in bundle")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let markerJSONs = try decoder.decode([MarkerJSON].self, from: data)
            
            // Convert JSON objects to HistoricalMarker objects
            markers = markerJSONs.compactMap { $0.toHistoricalMarker() }
            
            print("Successfully loaded \(markers.count) markers from JSON")
            
            // Update camera to center on Texas if markers were loaded
            if let firstMarker = markers.first {
                cameraPosition = .region(MKCoordinateRegion(
                    center: firstMarker.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 5.0, longitudeDelta: 5.0)
                ))
            }
        } catch {
            print("Error loading markers from JSON: \(error)")
        }
    }
}

extension MarkerMapViewModel: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Update camera to follow the user gently
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(center: location.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        }
        checkProximity(to: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }

    private func checkProximity(to location: CLLocation) {
        // Announce markers within 60 meters, avoid repeating the same marker
        let threshold: CLLocationDistance = 60
        for marker in markers {
            let distance = CLLocation(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude).distance(from: location)
            if distance <= threshold && !lastAnnouncedMarkerIDs.contains(marker.id) {
                lastAnnouncedMarkerIDs.insert(marker.id)
                nearbyMarker = marker
                onProximityMarker?(marker)
            }
        }
    }
}
