//SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

interface IMessageTransmitter {
    // ============ External Functions  ============
    /**
     * @notice Send the message to the destination domain and recipient
     * @dev Increment nonce, format the message, and emit `MessageSent` event with message information.
     * @param destinationDomain Domain of destination chain
     * @param recipient Address of message recipient on destination chain as bytes32
     * @param messageBody Raw bytes content of message
     * @return nonce reserved by message
     */
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes calldata messageBody
    ) external returns (uint64);

    /**
     * @notice Replace a message with a new message body and/or destination caller.
     * @dev The `originalAttestation` must be a valid attestation of `originalMessage`.
     * Reverts if msg.sender does not match sender of original message, or if the source domain of the original message
     * does not match this MessageTransmitter's local domain.
     * @param originalMessage original message to replace
     * @param originalAttestation attestation of `originalMessage`
     * @param newMessageBody new message body of replaced message
     * @param newDestinationCaller the new destination caller, which may be the
     * same as the original destination caller, a new destination caller, or an empty
     * destination caller (bytes32(0), indicating that any destination caller is valid.)
     */
    function replaceMessage(
        bytes calldata originalMessage,
        bytes calldata originalAttestation,
        bytes calldata newMessageBody,
        bytes32 newDestinationCaller
    ) external;

    /**
     * @notice Send the message to the destination domain and recipient, for a specified `destinationCaller` on the
     * destination domain.
     * @dev Increment nonce, format the message, and emit `MessageSent` event with message information.
     * WARNING: if the `destinationCaller` does not represent a valid address, then it will not be possible
     * to broadcast the message on the destination domain. This is an advanced feature, and the standard
     * sendMessage() should be preferred for use cases where a specific destination caller is not required.
     * @param destinationDomain Domain of destination chain
     * @param recipient Address of message recipient on destination domain as bytes32
     * @param destinationCaller caller on the destination domain, as bytes32
     * @param messageBody Raw bytes content of message
     * @return nonce reserved by message
     */
    function sendMessageWithCaller(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        bytes calldata messageBody
    ) external returns (uint64);

    /**
     * @notice Receive a message. Messages with a given nonce
     * can only be broadcast once for a (sourceDomain, destinationDomain)
     * pair. The message body of a valid message is passed to the
     * specified recipient for further processing.
     *
     * @dev Attestation format:
     * A valid attestation is the concatenated 65-byte signature(s) of exactly
     * `thresholdSignature` signatures, in increasing order of attester address.
     * ***If the attester addresses recovered from signatures are not in
     * increasing order, signature verification will fail.***
     * If incorrect number of signatures or duplicate signatures are supplied,
     * signature verification will fail.
     *
     * Message format:
     * Field                 Bytes      Type       Index
     * version               4          uint32     0
     * sourceDomain          4          uint32     4
     * destinationDomain     4          uint32     8
     * nonce                 8          uint64     12
     * sender                32         bytes32    20
     * recipient             32         bytes32    52
     * messageBody           dynamic    bytes      84
     * @param message Message bytes
     * @param attestation Concatenated 65-byte signature(s) of `message`, in increasing order
     * of the attester address recovered from signatures.
     * @return success bool, true if successful
     */
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool success);
}
