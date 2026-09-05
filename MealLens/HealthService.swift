import Foundation
import HealthKit
import Observation

@MainActor @Observable final class HealthService {
    private let store = HKHealthStore()
    var steps: Double?
    var activeEnergy: Double?
    var weight: Double?
    var weightDate: Date?
    var status = "건강 앱을 연결하면 활동과 체중을 함께 볼 수 있어요."
    var loading = false
    var connected = false
    private var requestID = UUID()

    func connect(on date: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { status = "이 기기에서는 건강 데이터를 사용할 수 없어요."; return }
        do {
            let types: Set<HKObjectType> = [HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned), HKQuantityType(.bodyMass)]
            try await store.requestAuthorization(toShare: [], read: types)
            connected = true
            await refresh(on: date)
        } catch { status = "건강 앱 연결을 완료하지 못했어요. 다시 시도해 주세요." }
    }
    func refresh(on date: Date) async {
        guard connected else { return }
        let token = UUID(); requestID = token
        loading = true
        steps = nil; activeEnergy = nil; weight = nil; weightDate = nil
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        do {
            async let stepValue = sum(.stepCount, unit: .count(), start: start, end: end)
            async let energyValue = sum(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end)
            async let mass = latestWeight(before: end)
            let (s, e, w) = try await (stepValue, energyValue, mass)
            guard requestID == token else { return }
            steps = s; activeEnergy = e; weight = w?.0; weightDate = w?.1
            status = "표시되지 않는 값은 기록이 없거나 읽기 권한이 없는 항목이에요."
        } catch {
            guard requestID == token else { return }
            status = "건강 데이터를 불러오지 못했어요. 다시 새로고침해 주세요."
        }
        if requestID == token { loading = false }
    }
    private func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: HKQuantityType(identifier), quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit)) }
            }
            store.execute(query)
        }
    }
    private func latestWeight(before end: Date) async throws -> (Double, Date)? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKQuantityType(.bodyMass), predicate: HKQuery.predicateForSamples(withStart: nil, end: end), limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else if let sample = samples?.first as? HKQuantitySample {
                    continuation.resume(returning: (sample.quantity.doubleValue(for: .gramUnit(with: .kilo)), sample.endDate))
                } else { continuation.resume(returning: nil) }
            }
            store.execute(query)
        }
    }
}
