//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import HummingbirdCore
import Logging
import NIOCore
import NIOHTTP1
import NIOWebSocket

public struct WebSocketClientChannel<Handler: WebSocketDataHandler>: ClientConnectionChannel {
    public enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }

    public typealias Value = EventLoopFuture<UpgradeResult>

    let url: String
    let handler: Handler
    let maxFrameSize: Int
    let additionalHeaders: HTTPFields

    init(handler: Handler, url: String, maxFrameSize: Int = 1 << 14, additionalHeaders: HTTPFields = .init()) {
        self.url = url
        self.handler = handler
        self.maxFrameSize = maxFrameSize
        self.additionalHeaders = additionalHeaders
    }

    public func setup(channel: any Channel, logger: Logger) -> NIOCore.EventLoopFuture<Value> {
        channel.eventLoop.makeCompletedFuture {
            let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                maxFrameSize: maxFrameSize,
                upgradePipelineHandler: { channel, _ in
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                        return UpgradeResult.websocket(asyncChannel)
                    }
                }
            )

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "0")
            let additionalHeaders = HTTPHeaders(self.additionalHeaders)
            headers.add(contentsOf: additionalHeaders)

            let requestHead = HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: self.url,
                headers: headers
            )

            let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
                upgradeRequestHead: requestHead,
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { channel in
                    channel.eventLoop.makeCompletedFuture {
                        return UpgradeResult.notUpgraded
                    }
                }
            )

            let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
            )

            return negotiationResultFuture
        }
    }

    public func handle(value: Value, logger: Logger) async throws {
        switch try await value.get() {
        case .websocket(let websocketChannel):
            let webSocket = WebSocketHandler(asyncChannel: websocketChannel, type: .client)
            let context = self.handler.alreadySetupContext ?? .init(logger: logger, allocator: websocketChannel.channel.allocator)
            await webSocket.handle(handler: self.handler, context: context)
        case .notUpgraded:
            // The upgrade to websocket did not succeed.
            logger.debug("Upgrade declined")
            throw WebSocketClientError.webSocketUpgradeFailed
        }
    }
}