//
//  DeviceDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/30/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import HealthKit
import LoopKit
import LoopKitUI


final class DeviceDataManager {

    private let queue = DispatchQueue(label: "com.loopkit.DeviceManagerQueue", qos: .utility)

    var pumpManager: PumpManagerUI? {
        didSet {
            // If the current CGMManager is a PumpManager, we clear it out.
            if cgmManager is PumpManagerUI {
                cgmManager = nil
            }

            setupPump()

            UserDefaults.appGroup.pumpManager = pumpManager
        }
    }

    let logger = DiagnosticLogger.shared

    private let log = DiagnosticLogger.shared.forCategory("DeviceManager")

    /// Remember the launch date of the app for diagnostic reporting
    private let launchDate = Date()

    /// Manages authentication for remote services
    let remoteDataManager = RemoteDataManager()

    private var nightscoutDataManager: NightscoutDataManager!

    var lastError: (date: Date, error: Error)? {
        return lockedLastError.value
    }
    private func setLastError(error: Error) {
        lockedLastError.value = (date: Date(), error: error)
    }
    private let lockedLastError: Locked<(date: Date, error: Error)?> = Locked(nil)

    // MARK: - CGM

    var cgmManager: CGMManager? {
        didSet {
            setupCGM()

            UserDefaults.appGroup.cgmManager = cgmManager
        }
    }

    /// TODO: Isolate to queue
    private func setupCGM() {
        cgmManager?.cgmManagerDelegate = self
        loopManager.glucoseStore.managedDataInterval = cgmManager?.managedDataInterval

        pumpManager?.updateBLEHeartbeatPreference()
    }

    private func setupPump() {
        pumpManager?.pumpManagerDelegate = self

        // Proliferate PumpModel preferences to DoseStore
        if let pumpRecordsBasalProfileStartEvents = pumpManager?.pumpRecordsBasalProfileStartEvents {
            loopManager?.doseStore.pumpRecordsBasalProfileStartEvents = pumpRecordsBasalProfileStartEvents
        }
    }

    // MARK: - Configuration

    // MARK: - WatchKit

    fileprivate var watchManager: WatchDataManager!

    // MARK: - Status Extension

    fileprivate var statusExtensionManager: StatusExtensionDataManager!

    // MARK: - Initialization

    private(set) var loopManager: LoopDataManager!

    init() {
        pumpManager = UserDefaults.appGroup.pumpManager as? PumpManagerUI
        if let cgmManager = UserDefaults.appGroup.cgmManager {
            self.cgmManager = cgmManager
        } else if UserDefaults.appGroup.isCGMManagerValidPumpManager {
            self.cgmManager = pumpManager as? CGMManager
        }

        remoteDataManager.delegate = self
        statusExtensionManager = StatusExtensionDataManager(deviceDataManager: self)
        loopManager = LoopDataManager(
            lastLoopCompleted: statusExtensionManager.context?.lastLoopCompleted,
            lastTempBasal: statusExtensionManager.context?.netBasal?.tempBasal
        )
        watchManager = WatchDataManager(deviceManager: self)
        nightscoutDataManager = NightscoutDataManager(deviceDataManager: self)

        loopManager.delegate = self
        loopManager.carbStore.syncDelegate = remoteDataManager.nightscoutService.uploader
        loopManager.doseStore.delegate = self

        setupPump()
        setupCGM()
    }
}


extension DeviceDataManager: RemoteDataManagerDelegate {
    func remoteDataManagerDidUpdateServices(_ dataManager: RemoteDataManager) {
        loopManager.carbStore.syncDelegate = dataManager.nightscoutService.uploader
    }
}


extension DeviceDataManager: CGMManagerDelegate {
    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        self.cgmManager = nil
    }

    func cgmManager(_ manager: CGMManager, didUpdateWith result: CGMResult) {
        /// TODO: Isolate to queue
        switch result {
        case .newData(let values):
            log.default("CGMManager:\(type(of: manager)) did update with new data")

            loopManager.addGlucose(values) { result in
                if manager.shouldSyncToRemoteService {
                    switch result {
                    case .success(let values):
                        self.nightscoutDataManager.uploadGlucose(values, sensorState: manager.sensorState)
                    case .failure:
                        break
                    }
                }

                self.pumpManager?.assertCurrentPumpData()
            }
        case .noData:
            log.default("CGMManager:\(type(of: manager)) did update with no data")

            pumpManager?.assertCurrentPumpData()
        case .error(let error):
            log.default("CGMManager:\(type(of: manager)) did update with error: \(error)")

            self.setLastError(error: error)
            pumpManager?.assertCurrentPumpData()
        }

        pumpManager?.updateBLEHeartbeatPreference()
    }

    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        return loopManager.glucoseStore.latestGlucose?.startDate
    }
}


extension DeviceDataManager: PumpManagerDelegate {
    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {
        log.default("PumpManager:\(type(of: pumpManager)) did adjust pump block by \(adjustment)s")

        AnalyticsManager.shared.pumpTimeDidDrift(adjustment)
    }

    func pumpManagerDidUpdatePumpBatteryChargeRemaining(_ pumpManager: PumpManager, oldValue: Double?) {
        log.default("PumpManager:\(type(of: pumpManager)) did update pump battery from \(String(describing: oldValue))")

        if let newValue = pumpManager.pumpBatteryChargeRemaining {
            if newValue == 0 {
                NotificationManager.sendPumpBatteryLowNotification()
            } else {
                NotificationManager.clearPumpBatteryLowNotification()
            }

            if let oldValue = oldValue, newValue - oldValue >= 0.5 {
                AnalyticsManager.shared.pumpBatteryWasReplaced()
            }
        }
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        log.default("PumpManager:\(type(of: pumpManager)) did update state")

        UserDefaults.appGroup.pumpManager = pumpManager
    }

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {
        log.default("PumpManager:\(type(of: pumpManager)) did fire BLE heartbeat")

        cgmManager?.fetchNewDataIfNeeded { (result) in
            if case .newData = result {
                AnalyticsManager.shared.didFetchNewCGMData()
            }

            if let manager = self.cgmManager {
                // TODO: Isolate to queue?
                self.cgmManager(manager, didUpdateWith: result)
            }
        }
    }

    func pumpManagerShouldProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool {
        return !(cgmManager?.providesBLEHeartbeat == true)
    }

    func pumpManager(_ pumpManager: PumpManager, didUpdateStatus status: PumpManagerStatus) {
        log.default("PumpManager:\(type(of: pumpManager)) did update status")

        loopManager.doseStore.device = status.device
        // Update the pump-schedule based settings
        loopManager.setScheduleTimeZone(status.timeZone)
        nightscoutDataManager.upload(pumpStatus: status)
    }

    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        log.default("PumpManager:\(type(of: pumpManager)) will deactivate")

        loopManager.doseStore.resetPumpData()
        self.pumpManager = nil
    }

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {
        log.default("PumpManager:\(type(of: pumpManager)) did update pumpRecordsBasalProfileStartEvents to \(pumpRecordsBasalProfileStartEvents)")

        loopManager.doseStore.pumpRecordsBasalProfileStartEvents = pumpRecordsBasalProfileStartEvents
    }

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        log.error("PumpManager:\(type(of: pumpManager)) did error: \(error)")

        setLastError(error: error)
        nightscoutDataManager.uploadLoopStatus(loopError: error)
    }

    func pumpManager(_ pumpManager: PumpManager, didReadPumpEvents events: [NewPumpEvent], completion: @escaping (_ error: Error?) -> Void) {
        log.default("PumpManager:\(type(of: pumpManager)) did read pump events")

        loopManager.addPumpEvents(events) { (error) in
            if let error = error {
                self.log.error("Failed to addPumpEvents to DoseStore: \(error)")
            }

            completion(error)
        }
    }
    
    //////////////////////////////////////////
    // MARK: - Set Temp Targets From NS
    // by LoopKit Authors Ken Stack, Katie DiSimone
    struct NStempTarget : Codable {
        let created_at : String
        let duration : Int
        let targetBottom : Double?
        let targetTop : Double?
        let notes : String?
    }
    
    func doubleIsEqual(_ a: Double, _ b: Double, _ precision: Double) -> Bool {
        return fabs(a - b) < precision
    }
    
    func setNStemp () {
        // data from URL logic from modified http://mrgott.com/swift-programing/33-rest-api-in-swift-4-using-urlsession-and-jsondecode
        //look at users nightscout treatments collection and implement temporary BG targets using an override called remoteTempTarget that was added to Loopkit
        //user set overrides always have precedence
        
        //check that NSRemote override has been setup
        var presets = self.loopManager.settings.overridePresets
        var idArray = [String]()
        for preset in presets {
            idArray.append(preset.name)
        }
        
        guard let index = idArray.index(of:"NSRemote") as? Int else {return}
        if let override = self.loopManager.settings.scheduleOverride, override.isActive() {
            //find which preset is active and see if its NSRemote
            if override.context == .preMeal || override.context == .custom {return}
            let raw = override.context.rawValue
            let rawpreset = raw["preset"] as! [String:Any]
            let name = rawpreset["name"] as! String
            //if a diffrent local preset is running don't change
            if name != "NSRemote" {return}
        }
        
        let nightscoutService = remoteDataManager.nightscoutService
        guard let nssite = nightscoutService.siteURL?.absoluteString  else {return}
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]
        //how far back to look for valid treatments in hours
        let treatmentWindow : TimeInterval = TimeInterval(.hours(24))
        let now : Date = Date()
        let lasteventDate : Date = now - treatmentWindow
        //only consider treatments from now back to treatmentWindow
        let urlString = nssite + "/api/v1/treatments.json?find[eventType]=Temporary%20Target&find[created_at][$gte]="+formatter.string(from: lasteventDate)+"&find[created_at][$lte]=" + formatter.string(from: now)
        guard let url = URL(string: urlString) else {
            return
        }
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = NSURLRequest.CachePolicy.reloadIgnoringCacheData
        session.dataTask(with: request as URLRequest) { (data, response, error) in
            if error != nil {
                
                return
            }
            guard let data = data else { return }
            
            do {
                let temptargets = try JSONDecoder().decode([NStempTarget].self, from: data)
                //check to see if we found some recent temp targets
                if temptargets.count == 0 {return}
                //find the index of the most recent temptargets - sort by date
                var cdates = [Date]()
                for item in temptargets {
                    cdates.append(formatter.date(from: (item.created_at as String))!)
                }
                let last = temptargets[cdates.index(of:cdates.max()!) as! Int]
                //if duration is 0 we dont care about minmax levels, if not we need them to exist as Double
                
                //cancel any prior remoteTemp if last duration = 0 and remote temp is active else return anyway
                if last.duration < 1 {
                    if let override = self.loopManager.settings.scheduleOverride, override.isActive() {
                        self.loopManager.settings.clearOverride()
                        NotificationManager.sendRemoteTempCancelNotification()
                    }
                    return
                }
                
                //NS doesnt check to see if a duration is created but no targets exist - so we have too
                if last.duration != 0 {
                    guard last.targetBottom != nil else {return}
                    guard last.targetTop != nil else {return}
                }
                
                if last.targetTop!.isLess(than: last.targetBottom!) {return}
                
                // set the remote temp if it's valid and not already set.  Handle the nil issue as well
                let endlastTemp = cdates.max()! + TimeInterval(.minutes(Double(last.duration)))
                if Date() < endlastTemp  {
                    let NStargetUnit = HKUnit.milligramsPerDeciliter
                    let userUnit = self.loopManager.settings.glucoseTargetRangeSchedule?.unit
                    //convert NS temp targets to an HKQuanity with units and set limits (low of 70 mg/dL, high of 300 mg/dL)
                    //ns temps are always given in mg/dL
                    
                    let lowerTarget : HKQuantity = HKQuantity(unit : NStargetUnit, doubleValue:max(50.0,last.targetBottom as! Double))
                    let upperTarget : HKQuantity = HKQuantity(unit : NStargetUnit, doubleValue:min(400.0,last.targetTop as! Double))
                    //set the temp if override isn't enabled or is nil ie never enabled
                    //if unwraps as nil set it to 1.0 - user only setting glucose range
                    var multiplier : Double = 100.0
                    if last.notes != nil {multiplier = Double(last.notes as! String) ?? 100.0}
                    //    if var multiplier = Double(last.notes as! String) else {multiplier = 100.0}
                    multiplier = multiplier / 100.0
                    //safety settings
                    if multiplier < 0.0 || multiplier > 3.0 {
                        multiplier = 1.0
                    }
                    if self.loopManager.settings.scheduleOverride == nil || self.loopManager.settings.scheduleOverride?.isActive() != true {
                        presets[index].settings.basalRateMultiplier = multiplier
                        presets[index].settings.carbRatioMultiplier = 1.0/multiplier
                        presets[index].settings.insulinSensitivityMultiplier = 1.0/multiplier
                        presets[index].duration = .finite(.minutes(Double(last.duration)))
                        presets[index].settings.targetRange = DoubleRange(minValue: lowerTarget.doubleValue(for: userUnit!), maxValue: upperTarget.doubleValue(for: userUnit!))
                        self.loopManager.settings.overridePresets = presets
                        let enactOverride = presets[index].createOverride(beginningAt: cdates.max()!)
                        self.loopManager.settings.scheduleOverride = enactOverride
                        
                        
                        
                        NotificationManager.sendRemoteTempSetNotification(lowTarget: String(format:"%.0f",lowerTarget.doubleValue(for: userUnit!)), highTarget: String(format:"%.0f", upperTarget.doubleValue(for: userUnit!)), multiplier: String(format:"%.2f",multiplier), duration: String(last.duration) )
                        
                        return
                    }
                    
                    // check to see if the last remote temp treatment is different from the current and if it is, then set it
                    let currentRange = presets[index].settings.targetRange
                    let duration = presets[index].duration.timeInterval ?? 1.0 as TimeInterval
                    let override = self.loopManager.settings.scheduleOverride
                    let startDate = override?.startDate
                    let activeDate = startDate! + duration
                    
                    if self.doubleIsEqual(presets[index].settings.basalRateMultiplier!, multiplier, 0.01) == false ||
                        self.doubleIsEqual((currentRange.maxValue), upperTarget.doubleValue(for: userUnit!), 1.0) == false ||
                        self.doubleIsEqual((currentRange.minValue), lowerTarget.doubleValue(for: userUnit!), 1.0) == false ||
                        abs(activeDate.timeIntervalSince(endlastTemp)) > TimeInterval(.minutes(2)) {
                        
                        presets[index].settings.basalRateMultiplier = multiplier
                        presets[index].settings.carbRatioMultiplier = 1.0/multiplier
                        presets[index].settings.insulinSensitivityMultiplier = 1.0/multiplier
                        presets[index].duration = .finite(.minutes(Double(last.duration)))
                        presets[index].settings.targetRange = DoubleRange(minValue: lowerTarget.doubleValue(for: userUnit!), maxValue: upperTarget.doubleValue(for: userUnit!))
                        self.loopManager.settings.overridePresets = presets
                        let enactOverride = presets[index].createOverride(beginningAt: cdates.max()!)
                        self.loopManager.settings.scheduleOverride = enactOverride
                        
                        NotificationManager.sendRemoteTempSetNotification(lowTarget: String(format:"%.0f",lowerTarget.doubleValue(for: userUnit!)), highTarget: String(format:"%.0f", upperTarget.doubleValue(for: userUnit!)), multiplier: String(format:"%.2f",multiplier), duration: String(last.duration) )
                        
                        return
                    }
                    
                }
                else {
                    //do nothing
                }
            } catch let jsonError {
                print("error in nstemp")
                print(jsonError)
                
                return
            }
            }.resume()
    }
    
    //
    //////////////////////////

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (_ result: PumpManagerResult<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool)>) -> Void) {
        log.default("PumpManager:\(type(of: pumpManager)) did read reservoir value")

        loopManager.addReservoirValue(units, at: date) { (result) in
            
            //////
            // update BG correction range overrides via NS
            // this call may be more appropriate somewhere
            let allowremoteTempTargets : Bool = true
            if allowremoteTempTargets == true {self.setNStemp()}
            /////
            
            switch result {
            case .failure(let error):
                self.log.error("Failed to addReservoirValue: \(error)")
                completion(.failure(error))
            case .success(let (newValue, lastValue, areStoredValuesContinuous)):
                completion(.success((newValue: newValue, lastValue: lastValue, areStoredValuesContinuous: areStoredValuesContinuous)))

                // Send notifications for low reservoir if necessary
                if let previousVolume = lastValue?.unitVolume {
                    guard newValue.unitVolume > 0 else {
                        NotificationManager.sendPumpReservoirEmptyNotification()
                        return
                    }

                    let warningThresholds: [Double] = [10, 20, 30]

                    for threshold in warningThresholds {
                        if newValue.unitVolume <= threshold && previousVolume > threshold {
                            NotificationManager.sendPumpReservoirLowNotificationForAmount(newValue.unitVolume, andTimeRemaining: nil)
                            break
                        }
                    }

                    if newValue.unitVolume > previousVolume + 1 {
                        AnalyticsManager.shared.reservoirWasRewound()

                        NotificationManager.clearPumpReservoirNotification()
                    }
                }
            }
        }
    }

    func pumpManagerRecommendsLoop(_ pumpManager: PumpManager) {
        log.default("PumpManager:\(type(of: pumpManager)) recommends loop")
        loopManager.loop()
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        return loopManager.doseStore.pumpEventQueryAfterDate
    }

    func startDateToFilterNewReservoirEvents(for manager: PumpManager) -> Date {
        return loopManager.doseStore.lastReservoirValue?.startDate ?? .distantPast
    }
}


extension DeviceDataManager: DoseStoreDelegate {
    func doseStore(_ doseStore: DoseStore,
        hasEventsNeedingUpload pumpEvents: [PersistedPumpEvent],
        completion completionHandler: @escaping (_ uploadedObjectIDURLs: [URL]) -> Void
    ) {
        /// TODO: Isolate to queue
        guard let uploader = remoteDataManager.nightscoutService.uploader else {
            completionHandler(pumpEvents.map({ $0.objectIDURL }))
            return
        }

        uploader.upload(pumpEvents, fromSource: "loop://\(UIDevice.current.name)") { (result) in
            switch result {
            case .success(let objects):
                completionHandler(objects)
            case .failure(let error):
                let logger = DiagnosticLogger.shared.forCategory("NightscoutUploader")
                logger.error(error)
                completionHandler([])
            }
        }
    }
}

extension DeviceDataManager {
    func enactBolus(units: Double, at startDate: Date = Date(), completion: @escaping (_ error: Error?) -> Void) {
        guard let pumpManager = pumpManager else {
            completion(LoopError.configurationError(.pumpManager))
            return
        }

        pumpManager.enactBolus(units: units, at: startDate, willRequest: { (units, date) in
            self.loopManager.addRequestedBolus(units: units, at: date, completion: nil)
        }) { (error) in
            if let error = error {
                self.log.error(error)
                NotificationManager.sendBolusFailureNotification(for: error, units: units, at: startDate)
                completion(error)
            } else {
                self.loopManager.addConfirmedBolus(units: units, at: Date()) {
                    completion(nil)
                }
            }
        }
    }
}

extension DeviceDataManager: LoopDataManagerDelegate {
    func loopDataManager(
        _ manager: LoopDataManager,
        didRecommendBasalChange basal: (recommendation: TempBasalRecommendation, date: Date),
        completion: @escaping (_ result: Result<DoseEntry>) -> Void
    ) {
        guard let pumpManager = pumpManager else {
            completion(.failure(LoopError.configurationError(.pumpManager)))
            return
        }

        log.default("LoopManager did recommend basal change")

        pumpManager.enactTempBasal(
            unitsPerHour: basal.recommendation.unitsPerHour,
            for: basal.recommendation.duration,
            completion: { result in
                switch result {
                case .success(let doseEntry):
                    completion(.success(doseEntry))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        )
    }
}


extension DeviceDataManager: CustomDebugStringConvertible {
    var debugDescription: String {
        return [
            Bundle.main.localizedNameAndVersion,
            "",
            "## DeviceDataManager",
            "launchDate: \(launchDate)",
            "lastError: \(String(describing: lastError))",
            "",
            cgmManager != nil ? String(reflecting: cgmManager!) : "cgmManager: nil",
            "",
            pumpManager != nil ? String(reflecting: pumpManager!) : "pumpManager: nil",
            "",
            String(reflecting: watchManager!),
            "",
            String(reflecting: statusExtensionManager!),
        ].joined(separator: "\n")
    }
}
