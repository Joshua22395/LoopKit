//
//  InsulinMath.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 1/30/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit


struct InsulinMath {

    /**
     Returns the percentage of total insulin effect remaining at a specified interval after delivery; also known as Insulin On Board (IOB).

     These are 4th-order polynomial fits of John Walsh's IOB curve plots, and they first appeared in GlucoDyn.

     See: https://github.com/kenstack/GlucoDyn

     - parameter time:           The interval after insulin delivery
     - parameter actionDuration: The total time of insulin effect

     - returns: The percentage of total insulin effect remaining
     */
    private static func walshPercentEffectRemainingAtTime(time: NSTimeInterval, actionDuration: NSTimeInterval) -> Double {

        switch time {
        case let t where t <= 0:
            return 1
        case let t where t >= actionDuration:
            return 0
        default:
            // We only have Walsh models for a few discrete action durations, so we scale other action durations appropriately to the nearest one.
            let nearestModeledDuration: NSTimeInterval

            switch actionDuration {
            case let x where x < NSTimeInterval(hours: 3):
                nearestModeledDuration = NSTimeInterval(hours: 3)
            case let x where x > NSTimeInterval(hours: 6):
                nearestModeledDuration = NSTimeInterval(hours: 6)
            default:
                nearestModeledDuration = NSTimeInterval(hours: round(actionDuration.hours))
            }

            let minutes = time.minutes * nearestModeledDuration / actionDuration

            switch nearestModeledDuration {
            case NSTimeInterval(hours: 3):
                return -3.2030e-9 * pow(minutes, 4) + 1.354e-6 * pow(minutes, 3) - 1.759e-4 * pow(minutes, 2) + 9.255e-4 * minutes + 0.99951
            case NSTimeInterval(hours: 4):
                return -3.310e-10 * pow(minutes, 4) + 2.530e-7 * pow(minutes, 3) - 5.510e-5 * pow(minutes, 2) - 9.086e-4 * minutes + 0.99950
            case NSTimeInterval(hours: 5):
                return -2.950e-10 * pow(minutes, 4) + 2.320e-7 * pow(minutes, 3) - 5.550e-5 * pow(minutes, 2) + 4.490e-4 * minutes + 0.99300
            case NSTimeInterval(hours: 6):
                return -1.493e-10 * pow(minutes, 4) + 1.413e-7 * pow(minutes, 3) - 4.095e-5 * pow(minutes, 2) + 6.365e-4 * minutes + 0.99700
            default:
                assertionFailure()
                return 0
            }
        }
    }

    private static func insulinOnBoardForContinuousDose(dose: DoseEntry, atDate date: NSDate, actionDuration: NSTimeInterval, delay: NSTimeInterval, delta: NSTimeInterval) -> Double {

        let doseDuration = dose.endDate.timeIntervalSinceDate(dose.startDate)  // t1
        let time = date.timeIntervalSinceDate(dose.startDate)
        var iob: Double = 0
        var doseDate = NSTimeInterval(0)  // i

        repeat {
            let segment = max(0, min(doseDate + delta, doseDuration) - doseDate) / doseDuration
            iob += segment * walshPercentEffectRemainingAtTime(time - delay - doseDate, actionDuration: actionDuration)
            doseDate += delta
        } while doseDate <= min(floor((time + delay) / delta) * delta, doseDuration)

        return iob
    }

    private static func insulinOnBoardForDose(dose: DoseEntry, atDate date: NSDate, actionDuration: NSTimeInterval, delay: NSTimeInterval, delta: NSTimeInterval) -> Double {
        let time = date.timeIntervalSinceDate(dose.startDate)
        let iob: Double

        if time >= 0 {
            if dose.unit == .Units {
                iob = dose.value * walshPercentEffectRemainingAtTime(time - delay, actionDuration: actionDuration)
            } else if dose.unit == .UnitsPerHour && dose.endDate.timeIntervalSinceDate(dose.startDate) <= 1.05 * delta {
                iob = dose.value * dose.endDate.timeIntervalSinceDate(dose.startDate) / NSTimeInterval(hours: 1) * walshPercentEffectRemainingAtTime(time - delay, actionDuration: actionDuration)
            } else {
                iob = dose.value * dose.endDate.timeIntervalSinceDate(dose.startDate) / NSTimeInterval(hours: 1) * insulinOnBoardForContinuousDose(dose, atDate: date, actionDuration: actionDuration, delay: delay, delta: delta)
            }
        } else {
            iob = 0
        }

        return iob
    }

    private static func glucoseEffectForContinuousDose(dose: DoseEntry, atDate date: NSDate, actionDuration: NSTimeInterval, delay: NSTimeInterval, delta: NSTimeInterval) -> Double {
        let doseDuration = dose.endDate.timeIntervalSinceDate(dose.startDate)  // t1
        let time = date.timeIntervalSinceDate(dose.startDate)
        var value: Double = 0
        var doseDate = NSTimeInterval(0)  // i

        repeat {
            let segment = max(0, min(doseDate + delta, doseDuration) - doseDate) / doseDuration
            value += segment * (1.0 - walshPercentEffectRemainingAtTime(time - delay - doseDate, actionDuration: actionDuration))
            doseDate += delta
        } while doseDate <= min(floor((time + delay) / delta) * delta, doseDuration)

        return value
    }

    private static func glucoseEffectForDose(dose: DoseEntry, atDate date: NSDate, actionDuration: NSTimeInterval, insulinSensitivity: Double, delay: NSTimeInterval, delta: NSTimeInterval) -> Double {
        let time = date.timeIntervalSinceDate(dose.startDate)
        let value: Double

        if time >= 0 {
            if dose.unit == .Units {
                value = dose.value * -insulinSensitivity * (1.0 - walshPercentEffectRemainingAtTime(time - delay, actionDuration: actionDuration))
            } else if dose.unit == .UnitsPerHour && dose.endDate.timeIntervalSinceDate(dose.startDate) <= 1.05 * delta {
                value = dose.value * -insulinSensitivity * dose.endDate.timeIntervalSinceDate(dose.startDate) / NSTimeInterval(hours: 1) * (1.0 - walshPercentEffectRemainingAtTime(time - delay, actionDuration: actionDuration))
            } else {
                value = dose.value * -insulinSensitivity * dose.endDate.timeIntervalSinceDate(dose.startDate) / NSTimeInterval(hours: 1) * glucoseEffectForContinuousDose(dose, atDate: date, actionDuration: actionDuration, delay: delay, delta: delta)
            }
        } else {
            value = 0
        }

        return value
    }

    /**
     It takes a MM pump about 40s to deliver 1 Unit while bolusing
     See: http://www.healthline.com/diabetesmine/ask-dmine-speed-insulin-pumps#3
     
     A basal rate of 30 U/hour (near-max) would deliver an additional 0.5 U/min.
     */
    private static let MaximumReservoirDropPerMinute = 2.0

    /**
     Converts a continuous sequence of reservoir values to a sequence of doses

     - parameter values: A collection of reservoir values, in chronological order

     - returns: An array of doses
     */
    static func doseEntriesFromReservoirValues<T: CollectionType where T.Generator.Element: ReservoirValue>(values: T) -> [DoseEntry] {

        var doses: [DoseEntry] = []
        var previousValue: T.Generator.Element?

        let numberFormatter = NSNumberFormatter()
        numberFormatter.numberStyle = .DecimalStyle
        numberFormatter.maximumFractionDigits = 3

        for value in values {
            if let previousValue = previousValue {
                let volumeDrop = previousValue.unitVolume - value.unitVolume
                let duration = value.startDate.timeIntervalSinceDate(previousValue.startDate)

                if duration > 0 && 0 <= volumeDrop && volumeDrop <= MaximumReservoirDropPerMinute * duration.minutes {
                    doses.append(DoseEntry(
                        type: .TempBasal,
                        startDate: previousValue.startDate,
                        endDate: value.startDate,
                        value: volumeDrop * NSTimeInterval(hours: 1) / duration,
                        unit: .UnitsPerHour,
                        description: "Reservoir decreased \(numberFormatter.stringFromNumber(volumeDrop) ?? String(volumeDrop))U over \(numberFormatter.stringFromNumber(duration.minutes) ?? String(duration.minutes))min"
                    ))
                }
            }

            previousValue = value
        }

        return doses
    }

    /**
     Maps a timeline of dose entries with overlapping start and end dates to a timeline of doses that represents actual insulin delivery.

     - parameter doses:     A timeline of dose entries, in chronological order

     - returns: An array of reconciled insulin delivery history, as TempBasal and Bolus records
     */
    static func reconcileDoses<T: CollectionType where T.Generator.Element == DoseEntry>(doses: T) -> [DoseEntry] {

        var reconciled: [DoseEntry] = []

        var lastTempBasal: DoseEntry?

        for dose in doses {
            switch dose.type {
            case .Bolus:
                reconciled.append(dose)
            case .TempBasal:
                if let temp = lastTempBasal {
                    reconciled.append(DoseEntry(
                        type: temp.type,
                        startDate: temp.startDate,
                        endDate: min(temp.endDate, dose.startDate),
                        value: temp.value,
                        unit: temp.unit,
                        description: temp.description
                    ))
                }

                lastTempBasal = dose
            case .Suspend:
                if let temp = lastTempBasal {
                    reconciled.append(DoseEntry(
                        type: temp.type,
                        startDate: temp.startDate,
                        endDate: min(temp.endDate, dose.startDate),
                        value: temp.value,
                        unit: temp.unit,
                        description: temp.description
                    ))

                    if temp.endDate > dose.endDate {
                        lastTempBasal = DoseEntry(
                            type: temp.type,
                            startDate: dose.endDate,
                            endDate: temp.endDate,
                            value: temp.value,
                            unit: temp.unit,
                            description: temp.description
                        )
                    } else {
                        lastTempBasal = nil
                    }
                }

                reconciled.append(dose)
            }
        }

        if let temp = lastTempBasal {
            reconciled.append(temp)
        }

        return reconciled
    }

    private static func normalizeBasalDose(dose: DoseEntry, againstBasalSchedule basalSchedule: BasalRateSchedule) -> [DoseEntry] {

        var normalizedDoses: [DoseEntry] = []
        let basalItems = basalSchedule.between(dose.startDate, dose.endDate)

        for (index, basalItem) in basalItems.enumerate() {
            let value = dose.value - basalItem.value
            let startDate: NSDate
            let endDate: NSDate

            if index == 0 {
                startDate = dose.startDate
            } else {
                startDate = basalItem.startDate
            }

            if index == basalItems.count - 1 {
                endDate = dose.endDate
            } else {
                endDate = basalItems[index + 1].startDate
            }

            normalizedDoses.append(DoseEntry(
                type: dose.type,
                startDate: startDate,
                endDate: endDate,
                value: value,
                unit: dose.unit,
                description: dose.description
            ))
        }

        return normalizedDoses
    }

    /**
     Normalizes a sequence of dose entries against a basal rate schedule to a new sequence where each TempBasal value is relative to the scheduled basal value during that time period.

     Doses which cross boundaries in the basal rate schedule are split into multiple entries.

     - parameter doses:         A sequence of dose entries
     - parameter basalSchedule: The basal rate schedule to normalize against

     - returns: An array of normalized dose entries
     */
    static func normalize<T: CollectionType where T.Generator.Element == DoseEntry>(doses: T, againstBasalSchedule basalSchedule: BasalRateSchedule) -> [DoseEntry] {

        var normalizedDoses: [DoseEntry] = []

        for dose in doses {
            if dose.unit == .UnitsPerHour {
                normalizedDoses += normalizeBasalDose(dose, againstBasalSchedule: basalSchedule)
            } else {
                normalizedDoses.append(dose)
            }
        }

        return normalizedDoses
    }

    /**
     Calculates the total insulin delivery for a collection of doses

     - parameter values: A collection of doses

     - returns: The total insulin insulin, in Units
     */
    static func totalDeliveryForDoses<T: CollectionType where T.Generator.Element == DoseEntry>(doses: T) -> Double {
        var total: Double = 0

        for dose in doses {
            switch dose.unit {
            case .Units:
                total += dose.value
            case .UnitsPerHour:
                total += dose.value * dose.endDate.timeIntervalSinceDate(dose.startDate) / NSTimeInterval(hours: 1)
            }
        }

        return total
    }

    /**
     Calculates the timeline of insulin remaining for a collection of doses

     - parameter doses:          A collection of doses
     - parameter actionDuration: The total time of insulin effect
     - parameter fromDate:       The date to begin the timeline
     - parameter toDate:         The date to end the timeline
     - parameter delay:          The time to delay the dose effect
     - parameter delta:          The differential between timeline entries

     - returns: A sequence of insulin amount remaining
     */
    static func insulinOnBoardForDoses<T: CollectionType where T.Generator.Element == DoseEntry>(
        doses: T,
        actionDuration: NSTimeInterval,
        fromDate: NSDate? = nil,
        toDate: NSDate? = nil,
        delay: NSTimeInterval = NSTimeInterval(minutes: 10),
        delta: NSTimeInterval = NSTimeInterval(minutes: 5)
    ) -> [InsulinValue] {
        guard let (startDate, endDate) = LoopMath.simulationDateRangeForSamples(doses, fromDate: fromDate, toDate: toDate, duration: actionDuration, delay: delay, delta: delta) else {
            return []
        }

        var date = startDate
        var values = [InsulinValue]()

        repeat {
            let value = doses.reduce(0) { (value, dose) -> Double in
                return value + insulinOnBoardForDose(dose, atDate: date, actionDuration: actionDuration, delay: delay, delta: delta)
            }

            values.append(InsulinValue(startDate: date, value: value))
            date = date.dateByAddingTimeInterval(delta)
        } while date <= endDate

        return values
    }

    /**
     Calculates the timeline of glucose effects for a collection of doses

     - parameter doses:          A collection of doses
     - parameter actionDuration: The total time of insulin effect
     - parameter fromDate:       The date to begin the timeline
     - parameter toDate:         The date to end the timeline
     - parameter delay:          The time to delay the dose effect
     - parameter delta:          The differential between timeline entries

     - returns: A sequence of glucose effects
     */
    static func glucoseEffectsForDoses<T: CollectionType where T.Generator.Element == DoseEntry>(
        doses: T,
        actionDuration: NSTimeInterval,
        insulinSensitivity: InsulinSensitivitySchedule,
        fromDate: NSDate? = nil,
        toDate: NSDate? = nil,
        delay: NSTimeInterval = NSTimeInterval(minutes: 10),
        delta: NSTimeInterval = NSTimeInterval(minutes: 5)
    ) -> [GlucoseEffect] {
        guard let (startDate, endDate) = LoopMath.simulationDateRangeForSamples(doses, fromDate: fromDate, toDate: toDate, duration: actionDuration, delay: delay, delta: delta) else {
            return []
        }

        var date = startDate
        var values = [GlucoseEffect]()
        let unit = HKUnit.milligramsPerDeciliterUnit()

        repeat {
            let value = doses.reduce(0) { (value, dose) -> Double in
                return value + glucoseEffectForDose(dose, atDate: date, actionDuration: actionDuration, insulinSensitivity: insulinSensitivity.quantityAt(dose.startDate).doubleValueForUnit(unit), delay: delay, delta: delta)
            }

            values.append(GlucoseEffect(startDate: date, quantity: HKQuantity(unit: unit, doubleValue: value)))
            date = date.dateByAddingTimeInterval(delta)
        } while date <= endDate

        return values
    }
}
