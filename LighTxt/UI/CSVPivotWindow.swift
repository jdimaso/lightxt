import AppKit
import Combine
import Charts
import SwiftUI

@MainActor
final class CSVPivotWindow: NSWindowController, NSWindowDelegate {
    private static var openWindows: [ObjectIdentifier: CSVPivotWindow] = [:]
    private let model: CSVPivotModel

    static func open(beside parent: NSWindow?, title: String, fields: [CSVAnalysisField],
                     rowCount: Int64? = nil, scan: @escaping CSVAnalysisScan) {
        guard !fields.isEmpty else { return }
        let controller = CSVPivotWindow(title: title, fields: fields, rowCount: rowCount, scan: scan)
        Self.openWindows[ObjectIdentifier(controller)] = controller
        if let parent, let window = controller.window, let screen = parent.screen {
            let available = screen.visibleFrame
            let margin: CGFloat = 8
            let right = available.maxX - parent.frame.maxX - margin
            let left = parent.frame.minX - available.minX - margin
            let space = max(left, right)
            if space >= window.minSize.width {
                let width = min(window.frame.width, space)
                let x = right >= left ? parent.frame.maxX + margin : parent.frame.minX - margin - width
                let height = min(window.frame.height, available.height)
                let y = min(max(parent.frame.maxY - height, available.minY), available.maxY - height)
                window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
            } else {
                window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 32, y: parent.frame.maxY - 32))
                window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
            }
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
    }

    private init(title: String, fields: [CSVAnalysisField], rowCount: Int64?, scan: @escaping CSVAnalysisScan) {
        model = CSVPivotModel(fields: fields, rowCount: rowCount, scan: scan)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "PivotViz — \(title)"
        window.minSize = NSSize(width: 740, height: 460)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CSVPivotView(model: model))
        super.init(window: window)
        window.delegate = self
        model.refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        Self.openWindows.removeValue(forKey: ObjectIdentifier(self))
    }
}

@MainActor
private final class CSVPivotModel: ObservableObject {
    let fields: [CSVAnalysisField]
    let names: [Int: String]
    private let scan: CSVAnalysisScan
    private let rowCount: Int64?
    @Published var rowField: Int?
    @Published var columnField: Int?
    @Published var metrics: [PivotMetric]
    @Published var rowPage = 0
    @Published var columnPage = 0
    @Published var chartPage = 0
    @Published var chartHover: String?
    private var resultDimensions: [Int] = []
    private var resultMetrics: [PivotMetric] = []
    var currentResult: CSVPivotResult? {
        dimensions == resultDimensions && metrics == resultMetrics ? result : nil
    }

    @Published var display = PivotDisplay.table
    @Published private(set) var result: CSVPivotResult?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(fields: [CSVAnalysisField], rowCount: Int64?, scan: @escaping CSVAnalysisScan) {
        self.fields = fields
        let duplicates = Set(Dictionary(grouping: fields, by: \.name).filter { $0.value.count > 1 }.keys)
        names = Dictionary(uniqueKeysWithValues: fields.map { field in
            (field.id, duplicates.contains(field.name) ? "\(field.name) [\(field.id + 1)]" : field.name)
        })
        self.scan = scan
        self.rowCount = rowCount
        rowField = nil
        metrics = [.init(operation: .rows, field: fields[0].id)]
    }

    var dimensions: [Int] { [rowField, columnField].compactMap { $0 } }
    var displays: [PivotDisplay] { PivotDisplay.available(dimensions: dimensions.count, metrics: metrics.count) }

    func metricTitle(_ index: Int) -> String {
        let metric = metrics[index]
        guard metric.operation != .rows else { return "Count rows" }
        return "\(metric.operation.rawValue) · \(names[metric.field] ?? "")"
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        loading = false
    }

    func refresh() {
        cancel()
        if !displays.contains(display) { display = .table }
        result = nil
        error = nil
        loading = true
        let id = generation
        let dimensions = dimensions, metrics = metrics, scan = scan, rowCount = rowCount
        task = Task { [weak self] in
            do {
                let result = try await CSVPivotResult.calculate(dimensions: dimensions, metrics: metrics, scan: scan, knownRowCount: rowCount)
                guard let self, generation == id, !Task.isCancelled else { return }
                resultDimensions = dimensions
                resultMetrics = metrics
                self.result = result
            } catch {
                guard let self, generation == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard let self, generation == id else { return }
            loading = false
            task = nil
        }
    }
}

@MainActor
private struct CSVPivotView: View {
    @ObservedObject var model: CSVPivotModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dimensionPicker("Rows", field: $model.rowField, excluding: model.columnField)
                    if model.rowField != nil {
                        dimensionPicker("Columns", field: $model.columnField, excluding: model.rowField)
                    }
                    Divider()
                    Text("Values").font(.headline)
                    ForEach(model.metrics.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Picker("Aggregation", selection: $model.metrics[i].operation) {
                                    ForEach(PivotOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.labelsHidden()
                                if model.metrics.count > 1 {
                                    Button { model.metrics.remove(at: i) } label: {
                                        Image(systemName: "minus.circle")
                                    }.buttonStyle(.borderless).accessibilityLabel("Remove metric \(i + 1)")
                                }
                            }
                            if model.metrics[i].operation != .rows {
                                Picker("Value column", selection: $model.metrics[i].field) {
                                    ForEach(model.fields) { field in Text(model.names[field.id] ?? field.name).tag(field.id) }
                                }.labelsHidden()
                            }
                        }
                    }
                    Button {
                        model.metrics.append(.init(operation: .sum, field: model.fields[0].id))
                    } label: { Label("Add metric", systemImage: "plus") }
                    .disabled(model.metrics.count >= 8)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 224)
            .background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display", selection: $model.display) {
                    ForEach(model.displays, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                if model.loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Calculating pivot…")
                        Button("Cancel") { model.cancel() }
                    }
                    Spacer()
                } else if let error = model.error {
                    Text(error).textSelection(.enabled)
                    Button("Retry") { model.refresh() }
                    Spacer()
                } else if let result = model.currentResult {
                    Text("\(result.recordCount.formatted()) source rows · \(result.rows.count.formatted()) groups")
                        .font(.callout).foregroundStyle(.secondary)
                    if result.rows.isEmpty {
                        Text("No rows match the current filters.")
                        Spacer()
                    } else if model.display == .table {
                        PivotGrid(result: result, dimensions: model.dimensions.map { model.names[$0] ?? "" },
                                  metrics: model.metrics.indices.map(model.metricTitle),
                                  rowPage: $model.rowPage, columnPage: $model.columnPage)
                    } else {
                        PivotChart(result: result, display: model.display,
                                   dimensionTitle: model.dimensions.first.flatMap { model.names[$0] } ?? "",
                                   metricTitles: model.metrics.indices.map(model.metricTitle), page: $model.chartPage,
                                   hovered: $model.chartHover)
                    }
                } else {
                    Button("Calculate pivot") { model.refresh() }
                    Spacer()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: model.rowField) { _, field in
            if field == nil { model.columnField = nil }
            reset()
        }
        .onChange(of: model.columnField) { _, _ in reset() }
        .onChange(of: model.metrics) { _, _ in reset() }
        .onChange(of: model.display) { _, _ in model.chartPage = 0 }
    }

    private func dimensionPicker(_ title: String, field: Binding<Int?>, excluding: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Picker(title, selection: field) {
                Text("None").tag(nil as Int?)
                ForEach(model.fields.filter { $0.id != excluding }) { item in
                    Text(model.names[item.id] ?? item.name).tag(Optional(item.id))
                }
            }.labelsHidden()
        }
    }

    private func reset() {
        model.chartHover = nil
        model.rowPage = 0
        model.columnPage = 0
        model.chartPage = 0
        model.refresh()
    }
}

private func pivotLabel(_ value: String) -> String { value.isEmpty ? "(empty)" : value }

private struct PivotPageControl: View {
    let name: String
    let count: Int
    let size: Int
    @Binding var page: Int

    var body: some View {
        if count > size {
            HStack(spacing: 6) {
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0).accessibilityLabel("Previous \(name)")
                Text("\(name) \(page * size + 1)–\(min(count, (page + 1) * size)) of \(count)")
                    .font(.caption).monospacedDigit()
                Button { page = min((count - 1) / size, page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled((page + 1) * size >= count).accessibilityLabel("Next \(name)")
            }.controlSize(.small)
        }
    }
}

private struct PivotGrid: View {
    let result: CSVPivotResult
    let dimensions: [String]
    let metrics: [String]
    @Binding var rowPage: Int
    @Binding var columnPage: Int

    var body: some View {
        let matrix = dimensions.count == 2
        let rowKeys = matrix ? result.rows.map { $0.dimensions[0] }.reduce(into: [String]()) {
            if $0.last != $1 { $0.append($1) }
        } : result.rows.map { $0.dimensions.first ?? "Total" }
        let columnKeys = matrix ? Set(result.rows.map { $0.dimensions[1] }).sorted {
            let compared = $0.localizedStandardCompare($1)
            return compared == .orderedSame ? $0 < $1 : compared == .orderedAscending
        } : [""]
        let groups = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.dimensions, $0.values) })
        let rowsPerPage = 40
        let columnsPerPage = max(1, 8 / metrics.count)
        let visibleKeys = Array(columnKeys.dropFirst(columnPage * columnsPerPage).prefix(columnsPerPage))
        VStack(alignment: .leading) {
            HStack {
                PivotPageControl(name: "Rows", count: rowKeys.count, size: rowsPerPage, page: $rowPage)
                PivotPageControl(name: "Columns", count: columnKeys.count, size: columnsPerPage, page: $columnPage)
            }
            ScrollView([.vertical, .horizontal]) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    if matrix {
                        GridRow {
                            Text(dimensions[1]).foregroundStyle(.secondary)
                            ForEach(visibleKeys, id: \.self) { key in
                                Text(pivotLabel(key)).fontWeight(.semibold).gridCellColumns(metrics.count)
                            }
                        }
                    }
                    GridRow {
                        Text(dimensions.first ?? "Group").fontWeight(.semibold)
                        ForEach(visibleKeys, id: \.self) { _ in
                            ForEach(metrics.indices, id: \.self) { Text(metrics[$0]).fontWeight(.semibold) }
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rowKeys.dropFirst(rowPage * rowsPerPage).prefix(rowsPerPage)), id: \.self) { row in
                        GridRow {
                            Text(pivotLabel(row)).lineLimit(1)
                            ForEach(visibleKeys, id: \.self) { col in
                                let key = matrix ? [row, col] : dimensions.isEmpty ? [] : [row]
                                ForEach(metrics.indices, id: \.self) { index in
                                    Text(groups[key]?[index].map { $0.formatted(.number.precision(.significantDigits(1...10))) } ?? "—")
                                        .monospacedDigit().gridColumnAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
private struct PivotChart: View {
    struct Point: Identifiable {
        let id: Int
        let label: String
        let series: String
        let x: Double
        let y: Double
    }

    let result: CSVPivotResult
    let display: PivotDisplay
    let dimensionTitle: String
    let metricTitles: [String]
    @Binding var page: Int
    @Binding var hovered: String?

    var body: some View {
        // Keep each chart page small enough to draw and label interactively.
        let pageSize = display == .scatter ? 128 : max(8, 48 / metricTitles.count)
        let rows = result.rows.dropFirst(page * pageSize).prefix(pageSize)
        let points = chartPoints(rows)
        let yScale = scale(points.map(\.y))
        let xScale = scale(points.map(\.x))
        VStack(alignment: .leading, spacing: 12) {
            PivotPageControl(name: "Groups", count: result.rows.count, size: pageSize, page: $page)
            if points.isEmpty {
                Text("No numeric values for this chart.").foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    if display == .bar {
                        BarMark(x: .value("Group", point.label), y: .value("Value", point.y / yScale))
                            .foregroundStyle(by: .value("Series", point.series)).position(by: .value("Series", point.series))
                    } else if display == .line {
                        LineMark(x: .value("Group", point.label), y: .value("Value", point.y / yScale),
                                 series: .value("Series", point.series))
                            .foregroundStyle(by: .value("Series", point.series)).symbol(.circle)
                    } else if display == .scatter {
                        PointMark(x: .value("X", point.x / xScale), y: .value("Y", point.y / yScale))
                            .foregroundStyle(by: .value("Series", point.series))
                            .accessibilityLabel(point.label)
                            .accessibilityValue(scatterDetails(point))
                    }
                }
                .chartXAxisLabel(axisLabel(display == .scatter ? metricTitles[0] : dimensionTitle,
                                           scale: display == .scatter ? xScale : 1))
                .chartYAxisLabel(axisLabel(display == .scatter ? metricTitles[1] :
                                            (metricTitles.count == 1 ? metricTitles[0] : "Value"), scale: yScale))
                .chartOverlay { proxy in
                    if display == .scatter {
                        GeometryReader { geometry in
                            Color.clear.contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    guard case .active(let location) = phase, let frame = proxy.plotFrame else {
                                        hovered = nil
                                        return
                                    }
                                    let origin = geometry[frame].origin
                                    var nearest: Point?
                                    var distance: CGFloat = 14
                                    for point in points {
                                        guard let x = proxy.position(forX: point.x / xScale),
                                              let y = proxy.position(forY: point.y / yScale) else { continue }
                                        let delta = hypot(location.x - origin.x - x, location.y - origin.y - y)
                                        if delta < distance { nearest = point; distance = delta }
                                    }
                                    let details = nearest.map(scatterDetails)
                                    if hovered != details { hovered = details }
                                }
                        }
                    }
                }
                .frame(minHeight: 180)
                if display == .scatter {
                    Text(hovered ?? "Hover over a point to see its group and values.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: page) { _, _ in hovered = nil }
        .onChange(of: display) { _, _ in hovered = nil }
    }

    private func scatterDetails(_ point: Point) -> String {
        let group = result.rows.first?.dimensions.count == 2 ? "\(point.label) · \(point.series)" : point.label
        return "\(group)   \(metricTitles[0]) \(point.x.formatted())   \(metricTitles[1]) \(point.y.formatted())"
    }

    private func chartPoints(_ rows: ArraySlice<PivotRow>) -> [Point] {
        var points: [Point] = []
        for row in rows {
            let label = pivotLabel(row.dimensions.first ?? "Total")
            if display == .scatter {
                guard let x = row.values[0], x.isFinite, let y = row.values[1], y.isFinite else { continue }
                let series = row.dimensions.count == 2 ? pivotLabel(row.dimensions[1]) : "Groups"
                points.append(.init(id: points.count, label: label, series: series, x: x, y: y))
            } else {
                for i in metricTitles.indices {
                    guard let y = row.values[i], y.isFinite else { continue }
                    let series = row.dimensions.count == 2 ? pivotLabel(row.dimensions[1]) : "\(i + 1). \(metricTitles[i])"
                    points.append(.init(id: points.count, label: label, series: series, x: 0, y: y))
                }
            }
        }
        return points
    }

    private func scale(_ values: [Double]) -> Double {
        let magnitude = values.lazy.map { abs($0) }.max() ?? 0
        guard magnitude > 0, magnitude > 1e12 || magnitude < 1e-6 else { return 1 }
        return pow(10, max(-308, floor(log10(magnitude))))
    }

    private func axisLabel(_ title: String, scale: Double) -> String {
        scale == 1 ? title : "\(title) (×10^\(Int(round(log10(scale)))))"
    }
}
