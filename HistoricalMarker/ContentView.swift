//
//  ContentView.swift
//  HistoricalMarker
//
//  Created by Christopher Gillam on 11/5/25.
//

import SwiftUI
import MapKit
import Combine

struct ContentView: View {
    @StateObject private var viewModel = MarkerMapViewModel()
    @StateObject private var speech = SpeechManager()
    @State private var selectedMarker: HistoricalMarker? = nil
    @State private var showDetails: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $viewModel.cameraPosition, bounds: MapCameraBounds(minimumDistance: 500)) {
                ForEach(viewModel.markers) { marker in
                    Annotation(marker.title, coordinate: marker.coordinate) {
                        Button(action: {
                            selectedMarker = marker
                            showDetails = true
                        }) {
                            ZStack {
                                Circle().fill(Color.blue.opacity(0.85)).frame(width: 28, height: 28)
                                Image(systemName: "mappin")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .accessibilityLabel(Text(marker.title))
                        }
                    }
                }
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapPitchToggle()
            }
            .mapStyle(.standard(elevation: .realistic))
            .onAppear {
                viewModel.requestLocationAuthorization()
                viewModel.loadSampleMarkers()
                speech.configureAudioSession(playOverOthers: viewModel.playOverAudio)
                viewModel.onProximityMarker = { marker in
                    if viewModel.autoReadEnabled {
                        speech.speak(marker: marker)
                    }
                }
            }
            .onChange(of: viewModel.playOverAudio) { _, newValue in
                speech.configureAudioSession(playOverOthers: newValue)
            }
            .onReceive(viewModel.$nearbyMarker.compactMap { $0 }) { marker in
                if viewModel.autoReadEnabled {
                    speech.speak(marker: marker)
                }
            }

            VStack(spacing: 8) {
                HStack {
                    Toggle(isOn: $viewModel.autoReadEnabled) {
                        Label("Auto-read nearby markers", systemImage: "speaker.wave.2.fill")
                    }
                    .toggleStyle(.switch)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding([.horizontal, .top])

                HStack(spacing: 12) {
                    Toggle(isOn: $viewModel.playOverAudio) {
                        Label("Play over music/directions", systemImage: "car.fill")
                    }
                    .toggleStyle(.switch)

                    Button(action: { speech.stop() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: $showDetails) {
            if let marker = selectedMarker {
                MarkerDetailView(marker: marker)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

struct MarkerDetailView: View {
    let marker: HistoricalMarker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(marker.title)
                    .font(.title.bold())
                if let subtitle = marker.subtitle {
                    Text(subtitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if let imageName = marker.imageName, !imageName.isEmpty {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Divider()
                Text(marker.text)
                    .font(.body)
                Spacer(minLength: 20)
                HStack {
                    Image(systemName: "mappin.circle")
                    Text("Lat: \(marker.coordinate.latitude), Lon: \(marker.coordinate.longitude)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
