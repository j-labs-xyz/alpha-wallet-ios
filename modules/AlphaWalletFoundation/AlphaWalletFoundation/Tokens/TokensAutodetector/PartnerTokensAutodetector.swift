//
//  PartnerTokensAutodetector.swift
//  AlphaWalletFoundation
//
//  Created by Vladyslav Shepitko on 14.04.2023.
//

import Foundation
import AlphaWalletCore
import Combine

class PartnerTokensAutodetector: TokensAutodetector {
    private let subject = PassthroughSubject<[TokenOrContract], Never>()
    private let contractToImportStorage: ContractToImportStorage
    private let tokensDataStore: TokensDataStore
    private let importToken: TokenImportable & TokenOrContractFetchable
    private let queue = DispatchQueue(label: "org.alphawallet.swift.partnerTokensAutodetector")
    private var cancellable = Set<AnyCancellable>()
    private let server: RPCServer

    var detectedTokensOrContracts: AnyPublisher<[TokenOrContract], Never> {
        subject.eraseToAnyPublisher()
    }

    init(contractToImportStorage: ContractToImportStorage,
         tokensDataStore: TokensDataStore,
         importToken: TokenImportable & TokenOrContractFetchable,
         server: RPCServer) {

        self.server = server
        self.importToken = importToken
        self.tokensDataStore = tokensDataStore
        self.contractToImportStorage = contractToImportStorage
    }

    func start() {
        Task { @MainActor in
            let contracts = await filter(contractsToDetect: contractToImportStorage.contractsToDetect)
            Just(contracts)
                .subscribe(on: queue)
                .flatMap { [importToken] contracts in
                    let publishers = contracts.map {
                        return importToken.fetchTokenOrContract(for: $0.contract, onlyIfThereIsABalance: $0.onlyIfThereIsABalance).mapToResult()
                    }
                    return Publishers.MergeMany(publishers).collect()
                }.receive(on: queue)
                .map { $0.compactMap { try? $0.get() } }
                .filter { !$0.isEmpty }
                .multicast(subject: subject)
                .connect()
                .store(in: &cancellable)
        }
    }

    func stop() {
        //no-op
    }

    func resume() {
        //no-op
    }

    private func filter(contractsToDetect: [ContractToImport]) async -> [ContractToImport] {
        let tokens = await tokensDataStore.tokens(for: [server])
        let deleted = await tokensDataStore.deletedContracts(forServer: server)
        let hidden = await tokensDataStore.hiddenContracts(forServer: server)
        return contractsToDetect.filter { $0.server == server }.filter {
            !tokens.map { $0.contractAddress }.contains($0.contract) &&
            !deleted.map { $0.contractAddress }.contains($0.contract) &&
            !hidden.map { $0.contractAddress }.contains($0.contract)
        }
    }
}
