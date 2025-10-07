import SwiftUI
import MapKit
import Network
import Combine
import CoreLocation
import UniformTypeIdentifiers
import SQLite3
import Compression

// MARK: - Models

struct Aircraft: Identifiable, Hashable {
    let hex: String
    var callsign: String?
    var altitude: Int?
    var groundSpeed: Int?
    var track: Int?
    var latitude: Double?
    var longitude: Double?
    var verticalRate: Int?
    var squawk: String?
    var lastSeen: Date = Date()
    var messageCount: Int = 0
    
    // Enriched data from database
    var registration: String?
    var aircraftType: String?
    var operatorName: String?
    
    var id: String { hex }
    
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    
    var displayName: String {
        if let registration = registration {
            return registration
        }
        return callsign?.trimmingCharacters(in: .whitespaces) ?? hex
    }
}

// MARK: - BaseStation Message Parser

struct BaseStationMessage {
    let messageType: String
    let transmissionType: Int?
    let sessionID: String?
    let aircraftID: String?
    let hexIdent: String
    let flightID: String?
    let dateMessageGenerated: String?
    let timeMessageGenerated: String?
    let dateMessageLogged: String?
    let timeMessageLogged: String?
    let callsign: String?
    let altitude: Int?
    let groundSpeed: Int?
    let track: Int?
    let latitude: Double?
    let longitude: Double?
    let verticalRate: Int?
    let squawk: String?
    
    init?(from line: String) {
        let parts = line.components(separatedBy: ",")
        guard parts.count >= 22, parts[0] == "MSG" else { return nil }
        
        self.messageType = parts[0]
        self.transmissionType = Int(parts[1])
        self.sessionID = parts[2].isEmpty ? nil : parts[2]
        self.aircraftID = parts[3].isEmpty ? nil : parts[3]
        self.hexIdent = parts[4]
        self.flightID = parts[5].isEmpty ? nil : parts[5]
        self.dateMessageGenerated = parts[6].isEmpty ? nil : parts[6]
        self.timeMessageGenerated = parts[7].isEmpty ? nil : parts[7]
        self.dateMessageLogged = parts[8].isEmpty ? nil : parts[8]
        self.timeMessageLogged = parts[9].isEmpty ? nil : parts[9]
        self.callsign = parts[10].isEmpty ? nil : parts[10]
        self.altitude = parts[11].isEmpty ? nil : Int(parts[11])
        self.groundSpeed = parts[12].isEmpty ? nil : Int(parts[12])
        self.track = parts[13].isEmpty ? nil : Int(parts[13])
        self.latitude = parts[14].isEmpty ? nil : Double(parts[14])
        self.longitude = parts[15].isEmpty ? nil : Double(parts[15])
        self.verticalRate = parts[16].isEmpty ? nil : Int(parts[16])
        self.squawk = parts[17].isEmpty ? nil : parts[17]
    }
}

// MARK: - Network Manager

class AircraftDatabase {
    static let shared = AircraftDatabase()
    private var database: [String: (registration: String?, type: String?, operatorName: String?)] = [:]
    
    func loadDatabase(from path: String) {
        // Check if it's a gzip file
        if path.hasSuffix(".gz") {
            loadGzipSQLite(from: path)
        } else if path.hasSuffix(".sqb") || path.hasSuffix(".db") || path.hasSuffix(".sqlite") {
            loadSQLite(from: path)
        } else if path.hasSuffix(".csv") {
            loadCSV(from: path)
        } else {
            print("Unknown database format")
        }
    }
    
    private func loadGzipSQLite(from path: String) {
        // Try to decompress using command line gunzip as it's more reliable
        let tempGzPath = FileManager.default.temporaryDirectory.appendingPathComponent("temp.sqb.gz")
        let tempSqbPath = FileManager.default.temporaryDirectory.appendingPathComponent("temp.sqb")
        
        do {
            // Copy to temp location
            try FileManager.default.copyItem(atPath: path, toPath: tempGzPath.path)
            
            // Use gunzip command
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            process.arguments = ["-f", tempGzPath.path]
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // gunzip removes .gz extension, so file is now at temp.sqb
                if FileManager.default.fileExists(atPath: tempSqbPath.path) {
                    loadSQLite(from: tempSqbPath.path)
                    try? FileManager.default.removeItem(at: tempSqbPath)
                } else {
                    print("Decompressed file not found")
                }
            } else {
                print("gunzip failed with status \(process.terminationStatus)")
            }
            
            try? FileManager.default.removeItem(at: tempGzPath)
        } catch {
            print("Could not decompress gzip: \(error)")
        }
    }
    
    private func decompressManual(data: Data) -> Data? {
        // Alternative: Manual gzip decompression (kept as backup)
        // Skip gzip header (10 bytes minimum)
        guard data.count > 10 else { return nil }
        
        var index = 0
        
        // Check gzip magic number
        guard data[0] == 0x1f && data[1] == 0x8b else {
            print("Not a valid gzip file")
            return nil
        }
        
        // Skip to deflate data (simplified - doesn't handle all gzip options)
        index = 10
        
        let deflateData = data.subdata(in: index..<data.count-8) // Skip footer too
        
        let destinationBufferSize = data.count * 20 // Larger estimate
        var destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destinationBuffer.deallocate() }
        
        let decompressedSize = deflateData.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) -> Int in
            let typedPointer = sourceBuffer.bindMemory(to: UInt8.self)
            return compression_decode_buffer(destinationBuffer, destinationBufferSize,
                                            typedPointer.baseAddress!, deflateData.count,
                                            nil, COMPRESSION_ZLIB)
        }
        
        guard decompressedSize > 0 else {
            return nil
        }
        
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
    
    private func loadSQLite(from path: String) {
        var db: OpaquePointer?
        
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            print("Could not open SQLite database at \(path)")
            sqlite3_close(db)
            return
        }
        
        let query = "SELECT ModeS, Registration, ICAOTypeCode, RegisteredOwners FROM Aircraft"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("Could not prepare query")
            sqlite3_close(db)
            return
        }
        
        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let icaoPtr = sqlite3_column_text(statement, 0)
            let regPtr = sqlite3_column_text(statement, 1)
            let typePtr = sqlite3_column_text(statement, 2)
            let operatorPtr = sqlite3_column_text(statement, 3)
            
            guard let icaoPtr = icaoPtr else { continue }
            let icao = String(cString: icaoPtr).lowercased()
            
            let registration = regPtr != nil ? String(cString: regPtr!) : nil
            let type = typePtr != nil ? String(cString: typePtr!) : nil
            let operatorName = operatorPtr != nil ? String(cString: operatorPtr!) : nil
            
            database[icao] = (registration, type, operatorName)
            count += 1
        }
        
        sqlite3_finalize(statement)
        sqlite3_close(db)
        
        print("Loaded \(count) aircraft from SQLite database")
    }
    
    private func loadCSV(from path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Could not load database from \(path)")
            return
        }
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines.dropFirst() { // Skip header
            let fields = line.components(separatedBy: ",")
            guard fields.count >= 4 else { continue }
            
            let icao = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            let registration = fields.count > 1 && !fields[1].isEmpty ? fields[1].trimmingCharacters(in: .whitespaces) : nil
            let type = fields.count > 3 && !fields[3].isEmpty ? fields[3].trimmingCharacters(in: .whitespaces) : nil
            let operatorName = fields.count > 5 && !fields[5].isEmpty ? fields[5].trimmingCharacters(in: .whitespaces) : nil
            
            database[icao] = (registration, type, operatorName)
        }
        
        print("Loaded \(database.count) aircraft from database")
    }
    
    func lookup(hex: String) -> (registration: String?, type: String?, operatorName: String?)? {
        return database[hex.lowercased()]
    }
}

class AircraftDataManager: ObservableObject {
    @Published var aircraft: [String: Aircraft] = [:]
    @Published var isConnected: Bool = false
    @Published var connectionError: String = ""
    @Published var totalMessages: Int = 0
    
    private var connection: NWConnection?
    private var receiveBuffer = ""
    private let queue = DispatchQueue(label: "com.i1090.network")
    
    var host: String = "localhost"
    var port: UInt16 = 30003
    
    private var cleanupTimer: Timer?
    
    func connect() {
        // Try IPv4 first, then IPv6
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        
        connection = NWConnection(to: endpoint, using: params)
        
        connection?.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                switch newState {
                case .ready:
                    self?.isConnected = true
                    self?.connectionError = ""
                    self?.startReceiving()
                case .failed(let error):
                    self?.isConnected = false
                    self?.connectionError = "Connection failed: \(error.localizedDescription)"
                case .waiting(let error):
                    self?.isConnected = false
                    self?.connectionError = "Waiting: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        
        connection?.start(queue: queue)
        
        // Start cleanup timer to remove stale aircraft
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.removeStaleAircraft()
        }
    }
    
    func disconnect() {
        connection?.cancel()
        connection = nil
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
    
    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processData(data)
            }
            
            if isComplete {
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.connectionError = "Connection closed"
                }
            } else if let error = error {
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.connectionError = "Receive error: \(error.localizedDescription)"
                }
            } else {
                self?.startReceiving()
            }
        }
    }
    
    private func processData(_ data: Data) {
        guard let string = String(data: data, encoding: .utf8) else { return }
        receiveBuffer += string
        
        let lines = receiveBuffer.components(separatedBy: .newlines)
        receiveBuffer = lines.last ?? ""
        
        for line in lines.dropLast() {
            if let message = BaseStationMessage(from: line) {
                updateAircraft(with: message)
            }
        }
    }
    
    private func updateAircraft(with message: BaseStationMessage) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var aircraft = self.aircraft[message.hexIdent] ?? Aircraft(hex: message.hexIdent)
            
            // Update from message
            if let callsign = message.callsign {
                aircraft.callsign = callsign
            }
            if let altitude = message.altitude {
                aircraft.altitude = altitude
            }
            if let groundSpeed = message.groundSpeed {
                aircraft.groundSpeed = groundSpeed
            }
            if let track = message.track {
                aircraft.track = track
            }
            if let latitude = message.latitude {
                aircraft.latitude = latitude
            }
            if let longitude = message.longitude {
                aircraft.longitude = longitude
            }
            if let verticalRate = message.verticalRate {
                aircraft.verticalRate = verticalRate
            }
            if let squawk = message.squawk {
                aircraft.squawk = squawk
            }
            
            // Enrich with database info if not already loaded
            if aircraft.registration == nil, let dbInfo = AircraftDatabase.shared.lookup(hex: message.hexIdent) {
                aircraft.registration = dbInfo.registration
                aircraft.aircraftType = dbInfo.type
                aircraft.operatorName = dbInfo.operatorName
            }
            
            aircraft.lastSeen = Date()
            aircraft.messageCount += 1
            
            self.aircraft[message.hexIdent] = aircraft
            self.totalMessages += 1
        }
    }
    
    private func removeStaleAircraft() {
        let staleThreshold: TimeInterval = 60 // Remove aircraft not seen for 60 seconds
        let now = Date()
        
        DispatchQueue.main.async { [weak self] in
            self?.aircraft = self?.aircraft.filter { _, aircraft in
                now.timeIntervalSince(aircraft.lastSeen) < staleThreshold
            } ?? [:]
        }
    }
    
    var aircraftArray: [Aircraft] {
        Array(aircraft.values).sorted { $0.displayName < $1.displayName }
    }
    
    var visibleAircraft: [Aircraft] {
        aircraftArray.filter { $0.coordinate != nil }
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var userLocation: CLLocationCoordinate2D?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestPermission() {
        #if os(macOS)
        // macOS doesn't need explicit authorization request
        if CLLocationManager.locationServicesEnabled() {
            startUpdating()
        }
        #else
        manager.requestWhenInUseAuthorization()
        #endif
    }
    
    func startUpdating() {
        manager.startUpdatingLocation()
    }
    
    func stopUpdating() {
        manager.stopUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        userLocation = locations.first?.coordinate
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        #if os(macOS)
        if authorizationStatus == .authorized {
            startUpdating()
        }
        #else
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            startUpdating()
        }
        #endif
    }
}

// MARK: - Map Annotations

class AircraftAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    private(set) var aircraft: Aircraft
    
    var title: String? { aircraft.displayName }
    var subtitle: String? {
        var parts: [String] = []
        if let alt = aircraft.altitude {
            parts.append("\(alt) ft")
        }
        if let speed = aircraft.groundSpeed {
            parts.append("\(speed) kt")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    
    init(id: String, coordinate: CLLocationCoordinate2D, aircraft: Aircraft) {
        self.id = id
        self.coordinate = coordinate
        self.aircraft = aircraft
        super.init()
    }
    
    func updateAircraft(_ aircraft: Aircraft) {
        self.aircraft = aircraft
    }
}

// MARK: - OpenStreetMap Tile Overlay

class OSMTileOverlay: MKTileOverlay {
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let urlString = "https://tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png"
        return URL(string: urlString)!
    }
}

// MARK: - Map View

struct AircraftMapView: NSViewRepresentable {
    let aircraft: [Aircraft]
    @Binding var selectedAircraft: Aircraft?
    let userLocation: CLLocationCoordinate2D?
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        
        // Add OpenStreetMap tile overlay
        let overlay = OSMTileOverlay(urlTemplate: nil)
        overlay.canReplaceMapContent = true
        mapView.addOverlay(overlay, level: .aboveLabels)
        
        // Set initial region based on user location or default
        let center = userLocation ?? CLLocationCoordinate2D(latitude: 42.9, longitude: -71.4)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
        )
        mapView.setRegion(region, animated: false)
        
        return mapView
    }
    
    func updateNSView(_ mapView: MKMapView, context: Context) {
        // Center on user location when first received
        if let userLocation = userLocation, !context.coordinator.hasLocationCentered {
            let region = MKCoordinateRegion(
                center: userLocation,
                span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
            )
            mapView.setRegion(region, animated: true)
            context.coordinator.hasLocationCentered = true
        }
        
        // Get current aircraft IDs
        let currentAircraftIDs = Set(aircraft.map { $0.hex })
        
        // Get existing annotations (excluding user location)
        let existingAnnotations = mapView.annotations.compactMap { $0 as? AircraftAnnotation }
        let existingIDs = Set(existingAnnotations.map { $0.id })
        
        // Remove annotations for aircraft that are no longer present
        let annotationsToRemove = existingAnnotations.filter { !currentAircraftIDs.contains($0.id) }
        mapView.removeAnnotations(annotationsToRemove)
        
        // Add annotations for new aircraft
        let newAircraftIDs = currentAircraftIDs.subtracting(existingIDs)
        let newAnnotations = aircraft.compactMap { aircraft -> AircraftAnnotation? in
            guard newAircraftIDs.contains(aircraft.hex),
                  let coordinate = aircraft.coordinate else { return nil }
            return AircraftAnnotation(id: aircraft.hex, coordinate: coordinate, aircraft: aircraft)
        }
        mapView.addAnnotations(newAnnotations)
        
        // Update existing annotations' coordinates and data
        for annotation in existingAnnotations {
            if let updatedAircraft = aircraft.first(where: { $0.hex == annotation.id }),
               let newCoordinate = updatedAircraft.coordinate {
                annotation.coordinate = newCoordinate
                // Update the annotation's aircraft reference for callout updates
                annotation.updateAircraft(updatedAircraft)
                
                // Force the annotation view to update its rotation
                if let annotationView = mapView.view(for: annotation) as? MKAnnotationView {
                    context.coordinator.updateAnnotationRotation(annotationView, for: updatedAircraft)
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        let parent: AircraftMapView
        var hasLocationCentered = false
        private var annotationImages: [Int: NSImage] = [:] // Cache rotated images
        
        init(_ parent: AircraftMapView) {
            self.parent = parent
        }
        
        func updateAnnotationRotation(_ annotationView: MKAnnotationView, for aircraft: Aircraft) {
            guard let track = aircraft.track else { return }
            
            // Check if we have this rotation cached
            if let cachedImage = annotationImages[track] {
                annotationView.image = cachedImage
                return
            }
            
            // Create and cache the rotated image
            let size = NSSize(width: 24, height: 24)
            let baseImage = NSImage(size: size)
            baseImage.lockFocus()
            
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: size.width/2, y: 0))
            triangle.line(to: CGPoint(x: size.width, y: size.height))
            triangle.line(to: CGPoint(x: size.width/2, y: size.height * 0.7))
            triangle.line(to: CGPoint(x: 0, y: size.height))
            triangle.close()
            
            NSColor.systemBlue.setFill()
            triangle.fill()
            
            baseImage.unlockFocus()
            
            let rotatedImage = NSImage(size: size)
            rotatedImage.lockFocus()
            
            let transform = NSAffineTransform()
            transform.translateX(by: size.width / 2, yBy: size.height / 2)
            transform.rotate(byDegrees: CGFloat(track))
            transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
            transform.concat()
            
            baseImage.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
            
            rotatedImage.unlockFocus()
            
            annotationImages[track] = rotatedImage
            annotationView.image = rotatedImage
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let aircraftAnnotation = annotation as? AircraftAnnotation else { return nil }
            
            let identifier = "AircraftAnnotation"
            
            // Create custom image-based view
            let imageView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            imageView.canShowCallout = true
            
            // Set the rotated image
            updateAnnotationRotation(imageView, for: aircraftAnnotation.aircraft)
            
            imageView.displayPriority = .required
            
            // Show callsign if available, otherwise hex
            let labelText = aircraftAnnotation.aircraft.callsign?.trimmingCharacters(in: .whitespaces) ?? aircraftAnnotation.aircraft.hex
            let label = NSTextField(labelWithString: labelText)
            label.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            label.textColor = .white
            label.drawsBackground = true
            label.backgroundColor = NSColor.black.withAlphaComponent(0.75)
            label.isBordered = false
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.cornerRadius = 3
            label.layer?.masksToBounds = true
            
            label.sizeToFit()
            
            // Add padding and position below airplane
            let padding: CGFloat = 4
            label.frame = CGRect(x: 12 - (label.frame.width + padding * 2) / 2,
                                y: 26,
                                width: label.frame.width + padding * 2,
                                height: label.frame.height + padding)
            
            // Remove old labels if any
            imageView.subviews.forEach { $0.removeFromSuperview() }
            imageView.addSubview(label)
            
            return imageView
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let aircraftAnnotation = view.annotation as? AircraftAnnotation {
                parent.selectedAircraft = aircraftAnnotation.aircraft
            }
        }
    }
}

// MARK: - Aircraft List View

struct AircraftListView: View {
    let aircraft: [Aircraft]
    @Binding var selectedAircraft: Aircraft?
    
    var body: some View {
        List(aircraft, selection: $selectedAircraft) { aircraft in
            AircraftRow(aircraft: aircraft)
                .tag(aircraft)
        }
    }
}

struct AircraftRow: View {
    let aircraft: Aircraft
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(aircraft.displayName)
                    .font(.headline)
                
                if let type = aircraft.aircraftType {
                    Text(type)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            
            HStack {
                if let alt = aircraft.altitude {
                    Label("\(alt) ft", systemImage: "arrow.up.circle.fill")
                        .font(.caption)
                }
                
                if let speed = aircraft.groundSpeed {
                    Label("\(speed) kt", systemImage: "gauge")
                        .font(.caption)
                }
                
                if let track = aircraft.track {
                    Label("\(track)°", systemImage: "location.north.fill")
                        .font(.caption)
                }
            }
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail View

struct AircraftDetailView: View {
    let aircraft: Aircraft
    @Binding var selectedAircraft: Aircraft?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        if let callsign = aircraft.callsign {
                            Text(callsign.trimmingCharacters(in: .whitespaces))
                                .font(.title)
                                .bold()
                        } else {
                            Text(aircraft.hex.uppercased())
                                .font(.title)
                                .bold()
                        }
                        
                        if let type = aircraft.aircraftType {
                            Text(type)
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        selectedAircraft = nil
                    }) {
                        Label("Back to Map", systemImage: "map")
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Divider()
                
                Group {
                    Text("Identification")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    DetailRow(label: "ICAO Hex", value: aircraft.hex.uppercased())
                    
                    if let callsign = aircraft.callsign {
                        DetailRow(label: "Callsign", value: callsign.trimmingCharacters(in: .whitespaces))
                    }
                    
                    if let registration = aircraft.registration {
                        DetailRow(label: "Registration", value: registration)
                    }
                    
                    if let operatorName = aircraft.operatorName {
                        DetailRow(label: "Operator", value: operatorName)
                    }
                    
                    if let type = aircraft.aircraftType {
                        DetailRow(label: "Aircraft Type", value: type)
                    }
                }
                
                Divider()
                
                Group {
                    Text("Position & Movement")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    if let lat = aircraft.latitude, let lon = aircraft.longitude {
                        DetailRow(label: "Latitude", value: String(format: "%.5f°", lat))
                        DetailRow(label: "Longitude", value: String(format: "%.5f°", lon))
                    }
                    
                    if let altitude = aircraft.altitude {
                        DetailRow(label: "Altitude", value: "\(altitude) ft")
                    }
                    
                    if let speed = aircraft.groundSpeed {
                        DetailRow(label: "Ground Speed", value: "\(speed) knots")
                    }
                    
                    if let track = aircraft.track {
                        DetailRow(label: "Track", value: "\(track)°")
                    }
                    
                    if let verticalRate = aircraft.verticalRate {
                        let direction = verticalRate > 0 ? "↑" : verticalRate < 0 ? "↓" : "→"
                        DetailRow(label: "Vertical Rate", value: "\(direction) \(abs(verticalRate)) ft/min")
                    }
                }
                
                Divider()
                
                Group {
                    Text("System Information")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    if let squawk = aircraft.squawk {
                        DetailRow(label: "Squawk", value: squawk)
                    }
                    
                    DetailRow(label: "Messages Received", value: "\(aircraft.messageCount)")
                    
                    let secondsAgo = Int(Date().timeIntervalSince(aircraft.lastSeen))
                    DetailRow(label: "Last Seen", value: "\(secondsAgo) seconds ago")
                }
                
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .bold()
        }
    }
}

// MARK: - Main App View

struct ContentView: View {
    @StateObject private var dataManager = AircraftDataManager()
    @StateObject private var locationManager = LocationManager()
    @State private var selectedAircraft: Aircraft?
    @State private var showSettings = false
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Status bar
                HStack {
                    Circle()
                        .fill(dataManager.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    
                    Text(dataManager.isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                    
                    if !dataManager.connectionError.isEmpty {
                        Text("(\(dataManager.connectionError))")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    Spacer()
                    
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.plain)
                    
                    Text("\(dataManager.visibleAircraft.count) aircraft")
                        .font(.caption)
                    
                    Text("\(dataManager.totalMessages) msgs")
                        .font(.caption)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                
                // Aircraft list
                AircraftListView(aircraft: dataManager.aircraftArray, selectedAircraft: $selectedAircraft)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            if let selected = selectedAircraft {
                AircraftDetailView(aircraft: selected, selectedAircraft: $selectedAircraft)
            } else {
                AircraftMapView(aircraft: dataManager.visibleAircraft, selectedAircraft: $selectedAircraft, userLocation: locationManager.userLocation)
            }
        }
        .onAppear {
            dataManager.connect()
            locationManager.requestPermission()
        }
        .onDisappear {
            dataManager.disconnect()
            locationManager.stopUpdating()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(dataManager: dataManager)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var dataManager: AircraftDataManager
    @State private var host: String = ""
    @State private var portString: String = ""
    @State private var databasePath: String = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.title)
                .bold()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("dump1090-fa Connection")
                    .font(.headline)
                
                HStack {
                    Text("Host:")
                        .frame(width: 80, alignment: .leading)
                    TextField("localhost", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("Port:")
                        .frame(width: 80, alignment: .leading)
                    TextField("30003", text: $portString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    
                    Text("(BaseStation format)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text("Common ports:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• 30003 - BaseStation format (recommended)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• 30002 - Raw Mode S")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• 30005 - Beast binary")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 450)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Aircraft Database (Optional)")
                    .font(.headline)
                
                HStack {
                    Text("DB Path:")
                        .frame(width: 80, alignment: .leading)
                    TextField("Path to BaseStation.sqb.gz", text: $databasePath)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowedContentTypes = [.commaSeparatedText, .database, .data]
                        panel.allowsOtherFileTypes = true
                        if panel.runModal() == .OK {
                            databasePath = panel.url?.path ?? ""
                        }
                    }
                }
                
                Button("Load Database") {
                    if !databasePath.isEmpty {
                        AircraftDatabase.shared.loadDatabase(from: databasePath)
                    }
                }
                .buttonStyle(.bordered)
                
                Text("Supports: BaseStation.sqb.gz (gzip), .sqb, .db, .sqlite, .csv")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Adds registration, aircraft type, and operator info")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 450)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Save & Reconnect") {
                    if let port = UInt16(portString) {
                        dataManager.host = host
                        dataManager.port = port
                        dataManager.disconnect()
                        dataManager.connect()
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(width: 550, height: 500)
        .onAppear {
            host = dataManager.host
            portString = String(dataManager.port)
            databasePath = ""
        }
    }
}

// MARK: - App Entry Point

@main
struct I1090App: App {
    var body: some Scene {
        WindowGroup("i1090") {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}
