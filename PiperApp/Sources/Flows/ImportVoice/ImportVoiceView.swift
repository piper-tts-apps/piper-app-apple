// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import SwiftUI
import PiperAppUtils

struct ImportVoiceHostModelView: View {

    @StateObject var hostModel: ImportVoiceHostModel
    @Environment(\.dismiss) var dismiss

    @ViewBuilder
    func importButton(image: ImageResource,
                      title: String,
                      subtitle: String = "",
                      fileName: String,
                      isPresented: Binding<Bool>,
                      isSelected: Bool) -> some View {
        Button {
            isPresented.wrappedValue.toggle()
        } label: {
            VStack {
                Image(image)
                    .resizable()
                    .frame(
                        minWidth: 30, maxWidth: 170,
                        minHeight: 30, maxHeight: 170
                    )
                    .scaledToFit()
                    .padding(.all, 20)
                    .tint(isSelected ? Color(.colorOfText) : Color(.gray) )
                VStack {
                    Text(title)
                        .font(.title)
                    Text(subtitle)
                        .font(.footnote)
                    Text(fileName)
                        .font(.headline)
                }
                .foregroundStyle(Color(.colorOfText))
            }
        }
        .buttonStyle(BorderlessButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityElement(children: .combine)
    }

    @State var isShowingFileSelector = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        importButton(image: .onnx,
                                     title: "select_model".localized,
                                     subtitle: "onnx_file".localized,
                                     fileName: hostModel.viewModel.selectedModel,
                                     isPresented: $isShowingFileSelector,
                                     isSelected: !hostModel.viewModel.selectedModel.isEmpty)
                        Spacer()
                        Divider()
                        Spacer()
                        importButton(image: .json,
                                     title: "select_json".localized,
                                     fileName: hostModel.viewModel.selectedJSON,
                                     isPresented: $isShowingFileSelector,
                                     isSelected: !hostModel.viewModel.selectedJSON.isEmpty)
                        Spacer()
                    }
                    .fileImporter(isPresented: $isShowingFileSelector,
                                  allowedContentTypes: [Constants.modelUTI, Constants.jsonUTI],
                                  allowsMultipleSelection: true) { results in
                        switch results {
                        case .success(let fileURLs):
                            hostModel.select(files: fileURLs)
                        case .failure(let error):
                            Log.error("Failed to import model files: \(error)")
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        hostModel.install()
                    } label: {
                        Text("update_model_in_app")
                            .font(.title2)
                    }
                    .disabled(hostModel.viewModel.selectedJSON.isEmpty ||
                              hostModel.viewModel.selectedModel.isEmpty)
                    Spacer()
                }
            }
            .navigationTitle("update_model_in_app")
            .onAppear {
                hostModel.viewModel.onDismiss = {
                    dismiss()
                }
            }
            .alert("error", isPresented: $hostModel.viewModel.showErrorMessage, actions: {
                Button("ok", role: .cancel) { }
            }, message: {
                Text(hostModel.viewModel.error?.humanReadableError ?? "unknown_error".localized)
            })
        }
    }
}
