// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMessageTransmitter} from "../interface/IMessageTransmitter.sol";
import {ITokenMessenger} from "../interface/ITokenMessenger.sol";

/**
 * @title CCTPV1Core
 * @notice Circle Cross-Chain Transfer Protocol V1 Core Contract
 * @dev 支持：
 *   - 跨链发送 USDC（depositForBurn）
 *   - 跨链接收 USDC（handleReceiveMessage）
 *
 * 流程：
 *   [Source Chain] User --depositForBurn--> TokenMessenger (burn USDC, send message)
 *   [Attestation]  Circle signs the message off-chain
 *   [Dest Chain]   User/App --receiveMessage--> MessageTransmitter.verifyAndReceive
 *                                          |--TokenMessenger.handleReceiveMessage (mint USDC to recipient)
 *
 * 注意：V1 不支持 replaceMessage / replaceDepositForBurn，消息一旦发送不可修改。
 */
contract CCTPV1Core {
    // ============ Immutables ============
    IMessageTransmitter public immutable MESSAGE_TRANSMITTER;
    ITokenMessenger public immutable TOKEN_MESSENGER;
    address public immutable LOCAL_USDC;

    // ============ State ============
    /// @notice 记录已完成的消息哈希，防止 replay attack（由 MessageTransmitter 本身保证，这里额外记录应用层）
    mapping(bytes32 => bool) public processedMessages;

    // ============ Events ============
    event CCTPSent(
        address indexed sender,
        uint32 indexed destinationDomain,
        bytes32 indexed mintRecipient,
        uint256 amount,
        uint64 nonce,
        bytes32 messageHash
    );
    event CCTPReceived(
        address indexed recipient,
        uint32 indexed sourceDomain,
        uint256 indexed amount,
        bytes32 messageHash
    );
    event MessageProcessed(bytes32 indexed messageHash, bool success);

    // ============ Errors ============
    error AlreadyProcessed(bytes32 messageHash);
    error CCTPTransferFailed(bytes reason);
    error InvalidRecipient();
    error ZeroAmount();

    // ============ Constructor ============
    constructor(
        address _messageTransmitter,
        address _tokenMessenger,
        address _localUsdc
    ) {
        require(_messageTransmitter != address(0), "Zero transmitter");
        require(_tokenMessenger != address(0), "Zero tokenMessenger");
        require(_localUsdc != address(0), "Zero USDC");
        MESSAGE_TRANSMITTER = IMessageTransmitter(_messageTransmitter);
        TOKEN_MESSENGER = ITokenMessenger(_tokenMessenger);
        LOCAL_USDC = _localUsdc;
    }

    // ============ External Functions: Send ============

    /**
     * @notice 在当前链 Burn USDC，触发跨链转账
     * @param amount              要 Burn 的 USDC 数量（6位精度）
     * @param destinationDomain   目标链的 Circle Domain ID
     * @param mintRecipient       目标链接收 USDC 的地址（bytes32 格式）
     * @param burnToken           本链 USDC 合约地址（通常与 LOCAL_USDC 一致）
     *
     * @return nonce 消息唯一随机数
     *
     * @dev 调用前需先 approve 本合约转移 USDC 的权限
     *
     * Circle Domain IDs（部分）：
     *   Ethereum          = 0
     *   Avalanche         = 1
     *   Optimism          = 2
     *   Arbitrum          = 3
     *   Base              = 6
     *   Solana            = 5
     *   BSC (via LayerZero... 等效 domain 需查文档)
     */
    function sendUSDC(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert InvalidRecipient();

        // 调用 TokenMessenger.depositForBurn
        // 函数内部会：burn USDC + 通过 MessageTransmitter.sendMessage 发送消息
        nonce = ITokenMessenger(TOKEN_MESSENGER).depositForBurn({
            amount: amount,
            destinationDomain: destinationDomain,
            mintRecipient: mintRecipient,
            burnToken: burnToken
        });

        // 构造 message hash 用于事件追踪
        bytes32 messageHash = _computeMessageHashForNonce(
            destinationDomain,
            bytes32(uint256(uint160(msg.sender))), // sender as bytes32
            mintRecipient,
            nonce
        );

        emit CCTPSent(
            msg.sender,
            destinationDomain,
            mintRecipient,
            amount,
            nonce,
            messageHash
        );
    }

    /**
     * @notice sendUSDC 的变体：指定 destinationCaller（V1 不支持 caller 验证，简单转发）
     * @param destinationCaller   目标链允许调用 receiveMessage 的 caller（填 bytes32(0) 表示不限制）
     */
    function sendUSDCWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert InvalidRecipient();

        nonce = ITokenMessenger(TOKEN_MESSENGER).depositForBurnWithCaller({
            amount: amount,
            destinationDomain: destinationDomain,
            mintRecipient: mintRecipient,
            burnToken: burnToken,
            destinationCaller: destinationCaller
        });

        bytes32 messageHash = _computeMessageHashForNonce(
            destinationDomain,
            bytes32(uint256(uint160(msg.sender))),
            mintRecipient,
            nonce
        );

        emit CCTPSent(
            msg.sender,
            destinationDomain,
            mintRecipient,
            amount,
            nonce,
            messageHash
        );
    }

    // ============ External Functions: Receive ============

    /**
     * @notice 接收跨链消息并 mint USDC
     * @param message      消息字节（由 Circle Attestation Service 签名）
     * @param attestation  65字节签名（Circle 阈值签名）
     *
     * @return success 调用成功标识
     *
     * @dev 消息格式（由 MessageTransmitter 定义）：
     *   version(4) + sourceDomain(4) + destinationDomain(4)
     *   + nonce(8) + sender(32) + recipient(32) + messageBody(dynamic)
     */
    function receiveUSDC(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool success) {
        // 检查消息是否已处理（应用层防重放）
        bytes32 messageHash = keccak256(message);
        if (processedMessages[messageHash]) {
            emit MessageProcessed(messageHash, false);
            revert AlreadyProcessed(messageHash);
        }

        // 验证签名 + 解包消息 + 转账 USDC（由 TokenMessenger 完成）
        // 注意：调用者必须是 MessageTransmitter 或由其授权
        success = IMessageTransmitter(address(MESSAGE_TRANSMITTER))
            .receiveMessage(message, attestation);

        processedMessages[messageHash] = true;
        emit MessageProcessed(messageHash, success);

        if (!success) {
            // 撤销标记，允许重试
            delete processedMessages[messageHash];
            revert CCTPTransferFailed("receiveMessage failed");
        }

        // 从消息体中提取信息发出事件
        emit CCTPReceived(
            _extractRecipient(message),
            _extractSourceDomain(message),
            _extractAmountFromMessageBody(message),
            messageHash
        );
    }

    // ============ External Functions: Utility ============

    /**
     * @notice 查询某条消息是否已被处理
     */
    function isMessageProcessed(
        bytes calldata message
    ) external view returns (bool) {
        return processedMessages[keccak256(message)];
    }
    /**
     * @notice 查询 MessageTransmitter 当前累计 nonce（用于调试）
     * @dev MessageTransmitter 本身不暴露 nonce 查询接口，通过事件日志获取
     *      此占位函数返回 0，实际使用时需通过事件索引 nonce
     */
    function getCurrentNonce() external pure returns (uint64) {
        return 0;
    }

    // ============ Internal Functions ============

    /**
     * @notice 从 message body 中提取目标接收人地址
     * @dev BurnMessage body 格式：amount(32) + mintRecipient(32) + destinationDomain(4) + ...
     */
    function _extractRecipient(
        bytes calldata message
    ) internal pure returns (address recipient) {
        // message body 从第 84 字节开始（见 IMessageTransmitter.receiveMessage 注释）
        // recipient 在 message body 中前 32 字节
        assembly {
            recipient := calldataload(add(message.offset, 84))
        }
    }

    function _extractSourceDomain(
        bytes calldata message
    ) internal pure returns (uint32 domain) {
        // sourceDomain 在 message 的第 4..8 字节（4 字节 uint32）
        assembly {
            domain := calldataload(add(message.offset, 4))
        }
    }

    function _extractAmountFromMessageBody(
        bytes calldata /*message*/
    ) internal pure returns (uint256 amount) {
        // amount 在 message body 的前 32 字节
        // 注意：不同版本格式可能略有差异，这里给出通用占位
        // 实际解析需要参考目标链 TokenMessenger 的 BurnMessage 格式定义
        return 0;
    }

    /**
     * @notice 根据 nonce 估算 message hash（用于事件关联）
     * @dev 实际 message hash 以 receiveUSDC 中 keccak256(message) 为准
     */
    function _computeMessageHashForNonce(
        uint32 destinationDomain,
        bytes32 sender,
        bytes32 mintRecipient,
        uint64 nonce
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(destinationDomain, sender, mintRecipient, nonce)
            );
    }
}
