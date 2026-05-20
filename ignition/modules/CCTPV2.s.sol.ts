/**
 * CCTPV2 Ignition 部署模块
 *
 * 用法：
 *   npx hardhat ignition deploy ignition/modules/CCTPV2.s.sol.ts
 *   npx hardhat ignition deploy ignition/modules/CCTPV2.s.sol.ts --network sepolia
 *
 * 参数（可覆盖）：
 *   npx hardhat ignition deploy ... \
 *     --parameters '{"messageTransmitter":"0x...","tokenMessenger":"0x...","localUsdc":"0x..."}'
 */

import { buildModule } from "@nomicfoundation/ignition-core";
import { CCTPV2Core } from "../../contracts/CCTPV2Core.sol";

export const CCTPV2Module = buildModule("CCTPV2Module", (m) => {
  // Circle Mainnet 合约地址（默认）
  const messageTransmitter = m.getParameter(
    "messageTransmitter",
    "0x0a392f9583F658Ca9D77F5E3E21372C2DE73F1e3"
  );
  const tokenMessenger = m.getParameter(
    "tokenMessenger",
    "0xbd3aB2D3eB3CCcE5dC24E1245D18841084cC2B62"
  );
  const localUsdc = m.getParameter(
    "localUsdc",
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  );

  const cctpV2Core = m.contract("CCTPV2Core", [
    messageTransmitter,
    tokenMessenger,
    localUsdc,
  ]);

  return { cctpV2Core };
});

export default CCTPV2Module;
