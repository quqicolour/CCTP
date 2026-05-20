// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IMessageTransmitter } from "../interface/IMessageTransmitter.sol";
import { ITokenMessenger } from "../interface/ITokenMessenger.sol";
import { CCTPV1Core } from "./CCTPV1Core.sol";

/**
 * @title CCTPV2Core
 * @notice Circle Cross-Chain Transfer Protocol V2 Core Contract
 * @dev 在 V1 基础上新增：
 *   - replaceMessage:      替换消息体或目标 caller（需原消息未被确认）
 *   - replaceDepositForBurn: 替换 mintRecipient 或 destinationCaller（无需重新 burn）
 *
 * V2 兼容 V1 所有功能，直接继承 CCTPV1Core。
 *
 * 典型 Stuck 场景：
 *   用户发送消息后长时间未获取 attestation → 使用 replaceMessage 重新发送消息体
 *   发送时目标地址填错              → 使用 replaceDepositForBurn 修改 mintRecipient
 *
 * 重要：replace 只能在消息未被确认前执行；同一 nonce 只允许一条消息最终确认。
 */
contract CCTPV2Core is CCTPV1Core {
    // ============ Additional Immutables (V2 新增) ============
    // V2 与 V1 使用相同的 MessageTransmitter / TokenMessenger 地址
    // 区别在于调用时的函数签名不同（replace* 系列）

    // ============ Additional Events (V2) ============
    event MessageReplaced(
        bytes32 indexed originalMessageHash,
        bytes32 newMessageHash,
        address indexed replacer
    );
    event DepositForBurnReplaced(
        bytes32 indexed originalMessageHash,
        bytes32 newMintRecipient,
        bytes32 newDestinationCaller,
        address indexed replacer
    );
    event ReplaceFailed(
        bytes32 indexed originalMessageHash,
        string reason
    );

    // ============ Additional Errors (V2) ============
    error ReplaceFailedWithReason(string reason);
    error ZeroDestinationCaller();
    error InvalidMessageFormat();

    // ============ Constructor ============
    constructor(
        address _messageTransmitter,
        address _tokenMessenger,
        address _localUsdc
    ) CCTPV1Core(_messageTransmitter, _tokenMessenger, _localUsdc) {}

    // ============ V2: Replace Functions ============

    /**
     * @notice 替换已发送消息的消息体或目标 caller（解决 attestation 卡住）
     * @dev 适用场景：
     *   - 消息发出后长时间未获得 attestation
     *   - 想更换消息内容（messageBody）
     *   - 想更换目标 caller（newDestinationCaller）
     *
     * 要求：
     *   - originalMessage 必须尚未被 receiveMessage 确认
     *   - msg.sender 必须与 originalMessage 的 sender 字段一致
     *   - 源域必须是当前链的 domain
     *
     * @param originalMessage       原始消息字节
     * @param originalAttestation   原始消息的 attestation（用于验证消息存在）
     * @param newMessageBody        新的消息体（填原值保持不变）
     * @param newDestinationCaller  新的目标 caller（填 bytes32(0) 表示不限制）
     *
     * V2 新增 core primitive，MessageTransmitter.replaceMessage
     */
    function replaceMessage(
        bytes calldata originalMessage,
        bytes calldata originalAttestation,
        bytes calldata newMessageBody,
        bytes32 newDestinationCaller
    ) external {
        bytes32 originalHash = keccak256(originalMessage);

        // 检查是否已处理（已确认的消息不可替换）
        if (this.isMessageProcessed(originalMessage)) {
            emit ReplaceFailed(originalHash, "Message already processed");
            revert ReplaceFailedWithReason("MESSAGE_ALREADY_PROCESSED");
        }

        // 验证新 caller 不为零（除非显式允许）
        // Circle 协议允许 bytes32(0) 表示不限制
        // 这里做额外校验（可选，与协议兼容）

        // 调用 MessageTransmitter.replaceMessage
        // V2：使用带有 caller 验证的 sendMessageWithCaller 重发
        // 注意：replaceMessage 是 MessageTransmitter 的原生方法
        IMessageTransmitter(address(MESSAGE_TRANSMITTER)).replaceMessage({
            originalMessage: originalMessage,
            originalAttestation: originalAttestation,
            newMessageBody: newMessageBody,
            newDestinationCaller: newDestinationCaller
        });

        // 构造新消息的 hash 用于事件追踪
        // 由于 replaceMessage 复用原 nonce，新消息 hash = keccak256(newMessageBody)
        bytes32 newHash = keccak256(abi.encodePacked(
            originalMessage[:84], // 保留原有定长头部
            keccak256(newMessageBody) // 新 body hash
        ));

        emit MessageReplaced(originalHash, newHash, msg.sender);
    }

    /**
     * @notice 替换 DepositForBurn 的 mintRecipient 或 destinationCaller（无需重新 burn）
     * @dev 适用场景：
     *   - 用户填错了目标地址（mintRecipient），想在不离谱的情况下修正
     *   - 想更换 destination caller
     *
     * 要求：
     *   - originalMessage 尚未被确认
     *   - msg.sender 必须是原消息的 sender（depositor）
     *
     * 注意：amount 和 burnToken 无法修改，只能改地址信息
     *
     * @param originalMessage         原始 DepositForBurn 消息
     * @param originalAttestation     原始消息的 attestation
     * @param newDestinationCaller    新的目标 caller（填 bytes32(0) 表示 any）
     * @param newMintRecipient        新的 mint 接收地址
     *
     * V2: TokenMessenger.replaceDepositForBurn
     */
    function replaceDepositForBurn(
        bytes calldata originalMessage,
        bytes calldata originalAttestation,
        bytes32 newDestinationCaller,
        bytes32 newMintRecipient
    ) external {
        bytes32 originalHash = keccak256(originalMessage);

        if (this.isMessageProcessed(originalMessage)) {
            emit ReplaceFailed(originalHash, "Deposit already processed");
            revert ReplaceFailedWithReason("DEPOSIT_ALREADY_PROCESSED");
        }
        if (newMintRecipient == bytes32(0)) revert InvalidRecipient();

        // 调用 TokenMessenger.replaceDepositForBurn
        // 内部完成：替换 BurnMessage 内容 + 通过 MessageTransmitter.replaceMessage 重发
        ITokenMessenger(address(TOKEN_MESSENGER)).replaceDepositForBurn({
            originalMessage: originalMessage,
            originalAttestation: originalAttestation,
            newDestinationCaller: newDestinationCaller,
            newMintRecipient: newMintRecipient
        });

        emit DepositForBurnReplaced(
            originalHash,
            newMintRecipient,
            newDestinationCaller,
            msg.sender
        );
    }

    // ============ V2: Enhanced Receive with Replace Support ============

    /**
     * @notice V2 接收消息（支持 replace 后的消息）
     * @param message      消息字节
     * @param attestation  attestation（原始消息的或 replace 后的都有效）
     *
     * @dev V2 的 receiveMessage 与 V1 完全兼容，同一个 MessageTransmitter
     *     replaceMessage 后的新消息同样可以用 receiveMessage 确认。
     *     此处直接复用 V1 实现。
     */
    function receiveUSDCV2(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool success) {
        // 复用 V1 的 receiveMessage 逻辑
        return this.receiveUSDC(message, attestation);
    }

    // ============ Utility: Simulate Replace Effect ============

    /**
     * @notice 预览 replaceDepositForBurn 后新消息的预期内容（不执行）
     * @dev 供前端/后端提前计算新消息 hash，用于追踪替换进度
     *
     * 注意：此函数只能读取本地存储，无法验证原消息有效性。
     *       真正的有效性由 replaceDepositForBurn 调用时链上验证。
     */
    function previewReplaceDepositForBurn(
        bytes calldata originalMessage,
        bytes32 newMintRecipient
    ) external pure returns (bytes32 newMessageBodyHash) {
        // 模拟 BurnMessage body 的替换效果
        // BurnMessage body = abi.encode(amount, mintRecipient, destinationDomain, burnToken)
        // 这里取原 body 的 hash + 新 mintRecipient 混合计算（近似）
        bytes32 originalBodyHash = keccak256(originalMessage[84:]); // body 从 84 开始
        return keccak256(abi.encode(originalBodyHash, newMintRecipient));
    }
}
