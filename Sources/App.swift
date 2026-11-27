import AppKit
import SwiftUI

@main
struct MeetingScribeApp: App {
    @State private var meeting = Meeting()

    var body: some Scene {
        Window("회의록 서기", id: "scribe") {
            MeetingView(meeting: meeting)
                .frame(minWidth: 850, minHeight: 580)
        }
        .defaultSize(width: 1060, height: 710)
    }
}

private struct MeetingView: View {
    @Bindable var meeting: Meeting
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingReset = false
    @State private var followingTranscript = true

    private var busy: Bool { meeting.phase != .idle || meeting.generating }

    var body: some View {
        VStack(spacing: 15) {
            header
            if !meeting.status.isEmpty {
                Label(meeting.status, systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.orange)
            }
            if let modelStatus = meeting.modelStatus {
                Label(modelStatus, systemImage: "cpu")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            HSplitView {
                transcriptPanel.frame(minWidth: 310)
                minutesPanel.frame(minWidth: 330)
            }
        }
        .padding(20)
        .onAppear { meeting.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, meeting.phase == .idle { meeting.refresh() }
        }
        .confirmationDialog("현재 내용을 지우고 새 회의를 시작할까요?",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("현재 내용 지우기", role: .destructive) { meeting.reset() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("보관할 내용은 먼저 파일로 저장하세요.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.indigo)
                TextField("회의 제목", text: $meeting.title)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("회의 제목")
                Spacer()
                switch meeting.phase {
                case .idle:
                    if meeting.hasMaterial {
                        Button("새 회의") { confirmingReset = true }.disabled(busy)
                    } else {
                        Button("기록 시작", systemImage: "record.circle") { Task { await meeting.start() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!meeting.confirmed || busy)
                    }
                case .preparing:
                    ProgressView().controlSize(.small)
                    Text("준비 중").foregroundStyle(.secondary)
                case .recording:
                    Button("기록 종료", systemImage: "stop.circle") { Task { await meeting.stop() } }
                        .buttonStyle(.borderedProminent).tint(.red)
                case .finishing:
                    ProgressView().controlSize(.small)
                    Text("정리 중").foregroundStyle(.secondary)
                }
            }

            if meeting.phase == .idle && !meeting.hasMaterial {
                HStack {
                    Picker("기록 방식", selection: $meeting.selection) {
                        Text("대면 회의 · 마이크만").tag(Meeting.microphoneOnly)
                        ForEach(meeting.availableApps, id: \.processIdentifier) { app in
                            Text("\(app.localizedName ?? "회의 앱") + 마이크").tag(app.bundleIdentifier ?? "")
                        }
                    }
                    .fixedSize()
                    Button("새로고침", systemImage: "arrow.clockwise") { meeting.refresh() }
                        .labelStyle(.iconOnly)
                    Spacer()
                    Toggle("참석자에게 기록을 알리고 동의를 받았습니다", isOn: $meeting.confirmed)
                }
                Text(meeting.isMicrophoneOnly
                     ? "Mac 마이크로 회의실 발언을 기록합니다."
                     : "Mac도 같은 회의에 오디오로 연결하고 회의 앱 마이크를 음소거하세요. Mac 출력은 이어폰으로 보내고 앱의 두 입력을 확인하세요.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if meeting.phase == .recording || meeting.phase == .finishing {
                HStack(spacing: 20) {
                    ForEach(meeting.recordingSources, id: \.self) { source in
                        ProgressView(value: meeting.levels[source] ?? 0) {
                            Text(source.rawValue).font(.caption)
                        }
                        .frame(width: 145)
                        .tint(source == .room ? .indigo : .teal)
                    }
                    Spacer()
                }
            }
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("실시간 받아쓰기").font(.headline)
                Spacer()
                Toggle("자동 스크롤", isOn: $followingTranscript).font(.caption)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(meeting.orderedEntries) { entry in
                            transcriptRow(entry.line, source: entry.source)
                        }
                        if meeting.entries.isEmpty {
                            Text("발언이 여기에 표시됩니다.").foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("transcript-end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .textSelection(.enabled)
                .onChange(of: meeting.entries.last?.id) { _, _ in
                    if followingTranscript { scroll.scrollTo("transcript-end", anchor: .bottom) }
                }

            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
        .padding(.trailing, 9)
    }

    private func transcriptRow(_ text: String, source: Source) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(source == .room ? Color.indigo : Color.teal)
                .frame(width: 6, height: 6).padding(.top, 6)
                .accessibilityLabel(source.rawValue)
            Text(text)
        }
    }

    private var minutesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(busy ? "회의록 초안" : "회의록").font(.headline)
                Spacer()
                if meeting.generating { ProgressView().controlSize(.small) }
                Button("다시 생성", systemImage: "arrow.clockwise") {
                    Task { await meeting.regenerate() }
                }.disabled(busy || meeting.entries.isEmpty)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $meeting.draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .disabled(busy || !meeting.hasMaterial)
                    .accessibilityLabel("회의록")
                if meeting.draft.isEmpty {
                    Text("기록 중 약 1분마다 초안을 갱신하고, 종료 후 최종 회의록을 생성합니다.")
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            HStack {
                Button("복사", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.draft, forType: .string)
                }.disabled(busy || meeting.draft.isEmpty)
                Spacer()
                Menu("저장", systemImage: "square.and.arrow.down") {
                    Button("회의록만 저장") { meeting.export(includeTranscript: false) }
                        .disabled(meeting.draft.isEmpty)
                    Button("받아쓰기 포함 저장") { meeting.export(includeTranscript: true) }
                }.disabled(busy || !meeting.hasMaterial)
            }
        }
        .padding(.leading, 9)
    }
}
