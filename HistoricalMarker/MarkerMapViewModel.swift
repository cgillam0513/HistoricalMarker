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
    var coordinate: CLLocationCoordinate2D
    let imageName: String?
    var needsGeocoding: Bool = false
    var addressString: String? = nil

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
        // If we have coordinates, use them directly
        if let latitude = coordinates.latitude,
           let longitude = coordinates.longitude {
            let subtitle = address.city.isEmpty ? address.county : "\(address.city), \(address.county)"
            
            return HistoricalMarker(
                title: title,
                subtitle: subtitle,
                text: description,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                imageName: images.first
            )
        }
        
        // If coordinates are missing but we have an address, return a marker
        // that will need geocoding (indicated by coordinates 0,0)
        if !address.city.isEmpty || !address.county.isEmpty {
            let subtitle = address.city.isEmpty ? address.county : "\(address.city), \(address.county)"
            
            return HistoricalMarker(
                title: title,
                subtitle: subtitle,
                text: description,
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), // Placeholder
                imageName: images.first,
                needsGeocoding: true,
                addressString: formatAddress()
            )
        }
        
        // No coordinates and no address - can't display this marker
        return nil
    }
    
    func formatAddress() -> String {
        var components: [String] = []
        if !address.city.isEmpty {
            components.append(address.city)
        }
        if !address.county.isEmpty {
            components.append(address.county)
        }
        components.append(address.state)
        return components.joined(separator: ", ")
    }
}

@MainActor
final class MarkerMapViewModel: NSObject, ObservableObject {
    // Map state
    @Published var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.0, longitude: -99.0), // Center of Texas
        span: MKCoordinateSpan(latitudeDelta: 5.0, longitudeDelta: 5.0)
    ))

    // Data
    @Published var visibleMarkers: [HistoricalMarker] = [] // Only markers in the visible region
    private var allMarkers: [HistoricalMarker] = [] // All loaded markers
    @Published var visibleRegion: MKCoordinateRegion? = nil
    @Published var totalMarkerCount: Int = 0
    @Published var visibleMarkerCount: Int = 0

    // Settings
    @Published var autoReadEnabled: Bool = true
    @Published var playOverAudio: Bool = true

    // Selection
    @Published var selectedMarker: HistoricalMarker? = nil

    // Proximity
    @Published var nearbyMarker: HistoricalMarker? = nil
    var onProximityMarker: ((HistoricalMarker) -> Void)?

    // Location
    private let locationManager = CLLocationManager()
    private var lastAnnouncedMarkerIDs: Set<UUID> = []
    
    // Performance optimization
    private var updateTask: Task<Void, Never>?

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
    
    // MARK: - Location Navigation
    func useCurrentLocation() {
        locationManager.startUpdatingLocation()
        if let location = locationManager.location {
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ))
            }
        }
    }
    
    func moveToLocation(coordinate: CLLocationCoordinate2D) {
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
    }
    
    // MARK: - Marker Selection
    func selectMarker(_ marker: HistoricalMarker) {
        selectedMarker = marker
    }
    
    func deselectMarker() {
        selectedMarker = nil
    }

    func loadSampleMarkers() {
        guard allMarkers.isEmpty else { return }
        
        // Try to load from JSON file
        guard let url = Bundle.main.url(forResource: "tx_historical_markers", withExtension: "json") else {
            print("Error: Could not find tx_historical_markers.json in bundle")
            return
        }
        
        Task {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                let markerJSONs = try decoder.decode([MarkerJSON].self, from: data)
                
                // Convert JSON objects to HistoricalMarker objects in background
                let markers = markerJSONs.compactMap { $0.toHistoricalMarker() }
                
                await MainActor.run {
                    self.allMarkers = markers
                    self.totalMarkerCount = markers.count
                    print("✓ Successfully loaded \(markers.count) markers from JSON")
                    
                    // Geocode markers that need it (in background)
                    self.geocodeMarkersIfNeeded()
                    
                    // Update visible markers for initial region
                    self.updateVisibleMarkers(for: self.currentRegion)
                }
            } catch {
                await MainActor.run {
                    print("✗ Error loading markers from JSON: \(error)")
                }
            }
        }
    }
    
    // MARK: - Region-based Filtering
    private var currentRegion: MKCoordinateRegion {
        // Default region centered on Texas
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 31.0, longitude: -99.0),
            span: MKCoordinateSpan(latitudeDelta: 5.0, longitudeDelta: 5.0)
        )
    }
    
    func updateVisibleMarkers(for region: MKCoordinateRegion) {
        // Cancel any pending update
        updateTask?.cancel()
        
        updateTask = Task {
            // Add a buffer to the visible region to preload nearby markers
            let bufferMultiplier = 1.5
            let expandedLatDelta = region.span.latitudeDelta * bufferMultiplier
            let expandedLonDelta = region.span.longitudeDelta * bufferMultiplier
            
            let minLat = region.center.latitude - expandedLatDelta / 2
            let maxLat = region.center.latitude + expandedLatDelta / 2
            let minLon = region.center.longitude - expandedLonDelta / 2
            let maxLon = region.center.longitude + expandedLonDelta / 2
            
            // Filter markers in background
            let filtered = allMarkers.filter { marker in
                !marker.needsGeocoding &&
                marker.coordinate.latitude >= minLat &&
                marker.coordinate.latitude <= maxLat &&
                marker.coordinate.longitude >= minLon &&
                marker.coordinate.longitude <= maxLon
            }
            
            // Check if task was cancelled
            if Task.isCancelled { return }
            
            await MainActor.run {
                self.visibleMarkers = filtered
                self.visibleMarkerCount = filtered.count
                self.visibleRegion = region
            }
        }
    }
    
    // MARK: - Geocoding
    private func geocodeMarkersIfNeeded() {
        let markersNeedingGeocoding = allMarkers.filter { $0.needsGeocoding }
        
        guard !markersNeedingGeocoding.isEmpty else { return }
        
        print("Geocoding \(markersNeedingGeocoding.count) markers with missing coordinates...")
        
        // Limit geocoding to a reasonable batch size
        let batchSize = 50
        let markersToGeocode = Array(markersNeedingGeocoding.prefix(batchSize))
        
        // Geocode in batches to avoid overwhelming the service
        for (index, marker) in markersToGeocode.enumerated() {
            // Add a delay between requests to be respectful of the geocoding service
            Task {
                try? await Task.sleep(nanoseconds: UInt64(index) * 200_000_000) // 0.2s delay per request
                await geocodeMarker(marker)
            }
        }
    }
    
    private func geocodeMarker(_ marker: HistoricalMarker) async {
        guard let address = marker.addressString else { return }
        
        let geocoder = CLGeocoder()
        
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            
            if let location = placemarks.first?.location {
                // Update the marker with the geocoded coordinates
                if let index = allMarkers.firstIndex(where: { $0.id == marker.id }) {
                    await MainActor.run {
                        allMarkers[index].coordinate = location.coordinate
                        allMarkers[index].needsGeocoding = false
                        
                        // Update visible markers if this marker is in the visible region
                        if let region = visibleRegion {
                            updateVisibleMarkers(for: region)
                        }
                    }
                }
            }
        } catch {
            // Silently fail for geocoding errors to avoid log spam
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
        // Only check visible markers for proximity (performance optimization)
        for marker in visibleMarkers {
            let distance = CLLocation(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude).distance(from: location)
            if distance <= threshold && !lastAnnouncedMarkerIDs.contains(marker.id) {
                lastAnnouncedMarkerIDs.insert(marker.id)
                nearbyMarker = marker
                onProximityMarker?(marker)
            }
        }
    }
}
