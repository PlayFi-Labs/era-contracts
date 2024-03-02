import { hashBytecode } from "zksync-web3/build/src/utils";
import type { CodeOracleTest } from "../typechain";
import { CodeOracleTestFactory, KeccakTestFactory } from "../typechain";
import { REAL_CODE_ORACLE_CONTRACT_ADDRESS } from "./shared/constants";
import { getWallets, loadArtifact, publishBytecode, setCode, getCode, deployContract } from "./shared/utils";
import { ethers, network } from "hardhat";
import { readYulBytecode } from "../scripts/utils";
import { Language } from "../scripts/constants";
import type { BytesLike } from "ethers";
import { expect } from "chai";
import * as hre from "hardhat";
import { prepareEnvironment } from "./shared/mocks";

import { ec as EC } from "elliptic";

describe("Sekp256r1 tests", function () {
  let oldCodeOracleCode: string;
  let testedCodeOracleCode: string;

  let codeOracleTest: CodeOracleTest;

  before(async () => {
    await prepareEnvironment();

    oldCodeOracleCode = await getCode(REAL_CODE_ORACLE_CONTRACT_ADDRESS);
    codeOracleTest = (await deployContract("CodeOracleTest", [])) as CodeOracleTest;

    testedCodeOracleCode = readYulBytecode({
      codeName: "CodeOracle",
      path: "precompiles",
      lang: Language.Yul,
      address: ethers.constants.AddressZero,
    });

    await setCode(REAL_CODE_ORACLE_CONTRACT_ADDRESS, testedCodeOracleCode);
  });

  it("Should correctly decommit existing code", async () => {
    // Just some valid zkEVM bytecode, but to skip publishing we re-use
    // the code of the code oracle itself.
    const bytecode = testedCodeOracleCode;

    const versionedHash = hashBytecode(bytecode);
    const keccakHash = ethers.utils.keccak256(bytecode);
    await codeOracleTest.codeOracleTest(versionedHash, keccakHash);
  });

  it("Should correctly decommit large existing code", async () => {
    // Just some valid zkEVM bytecode, but to skip publishing we re-use
    // the code of the code oracle itself.
    const largeBytecode = generateLargeBytecode();
    await publishBytecode(largeBytecode);

    const versionedHash = hashBytecode(largeBytecode);
    const keccakHash = ethers.utils.keccak256(largeBytecode);
    await codeOracleTest.codeOracleTest(versionedHash, keccakHash);
  });

  it("Should refuse to decommit unknown code", async () => {
    // Just some valid zkEVM bytecode, but to skip publishing we re-use
    // the code of the code oracle itself.
    const unknownLargeBytecode = generateLargeBytecode();

    const versionedHash = hashBytecode(unknownLargeBytecode);
    const keccakHash = ethers.utils.keccak256(unknownLargeBytecode);
    await expect(codeOracleTest.codeOracleTest(versionedHash, keccakHash)).to.be.rejectedWith("CodeOracle call failed");
  });

  after(async () => {
    await setCode(REAL_CODE_ORACLE_CONTRACT_ADDRESS, oldCodeOracleCode);
  });
});

function generateLargeBytecode() {
  // The rough length of the packed bytecode should be 350_000 / 4 = 87500,
  // which should fit into a batch
  const BYTECODE_LEN = 350_016 + 32; // +32 to ensure validity of the bytecode

  // Our current packing algorithm uses 8-byte chunks for dictionary and
  // so in order to make an effectively-packable bytecode, we need to have bytecode
  // consist of the same 2 types of 8-byte chunks.
  // Note, that instead of having 1 type of 8-byte chunks, we need 2 in order to have
  // a unique bytecode for each test run.
  const CHUNK_TYPE_1 = "00000000";
  const CHUNK_TYPE_2 = "ffffffff";

  let bytecode = "0x";
  while (bytecode.length < BYTECODE_LEN * 2 + 2) {
    if (Math.random() < 0.5) {
      bytecode += CHUNK_TYPE_1;
    } else {
      bytecode += CHUNK_TYPE_2;
    }
  }

  return bytecode;
}