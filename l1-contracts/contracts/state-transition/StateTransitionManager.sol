// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Diamond} from "./libraries/Diamond.sol";
import {DiamondProxy} from "./chain-deps/DiamondProxy.sol";
import {IAdmin} from "./chain-interfaces/IAdmin.sol";
import {IDefaultUpgrade} from "../upgrades/IDefaultUpgrade.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IStateTransitionManager, StateTransitionManagerInitializeData} from "./IStateTransitionManager.sol";
import {ISystemContext} from "./l2-deps/ISystemContext.sol";
import {IZkSyncHyperchain} from "./chain-interfaces/IZkSyncHyperchain.sol";
import {FeeParams} from "./chain-deps/ZkSyncHyperchainStorage.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../common/L2ContractAddresses.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ProposedUpgrade} from "../upgrades/BaseZkSyncUpgrade.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, SYSTEM_UPGRADE_L2_TX_TYPE} from "../common/Config.sol";
import {VerifierParams} from "./chain-interfaces/IVerifier.sol";

/// @title StateTransition contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract StateTransitionManager is IStateTransitionManager, ReentrancyGuard, Ownable2Step {
    /// @notice Address of the bridgehub
    address public immutable bridgehub;

    /// @notice The mapping from chainId => hyperchain contract
    mapping(uint256 chainId => address chainContract) public hyperchain;

    /// @dev The batch zero hash, calculated at initialization
    bytes32 public storedBatchZero;

    /// @dev The stored cutData for diamond cut
    bytes32 public initialCutHash;

    /// @dev The genesisUpgrade contract address, used to setChainId
    address public genesisUpgrade;

    /// @dev The current protocolVersion
    uint256 public protocolVersion;

    /// @dev The validatorTimelock contract address, used to setChainId
    address public validatorTimelock;

    /// @dev The stored cutData for upgrade diamond cut. protocolVersion => cutHash
    mapping(uint256 protocolVersion => bytes32 cutHash) public upgradeCutHash;

    /// @dev The address used to manage non critical updates
    address public admin;

    /// @dev The address to accept the admin role
    address private pendingAdmin;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _bridgehub) reentrancyGuardInitializer {
        bridgehub = _bridgehub;
    }

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        require(msg.sender == bridgehub, "STM: only bridgehub");
        _;
    }

    /// @notice the admin can call, for non-critical updates
    modifier onlyOwnerOrAdmin() {
        require(msg.sender == admin || msg.sender == owner(), "STM: not owner or admin");
        _;
    }

    function getChainAdmin(uint256 _chainId) external view override returns (address) {
        return IZkSyncHyperchain(hyperchain[_chainId]).getAdmin();
    }

    /// @dev initialize
    function initialize(
        StateTransitionManagerInitializeData calldata _initializeData
    ) external reentrancyGuardInitializer {
        require(_initializeData.owner != address(0), "STM: owner zero");
        _transferOwnership(_initializeData.owner);

        genesisUpgrade = _initializeData.genesisUpgrade;
        protocolVersion = _initializeData.protocolVersion;
        validatorTimelock = _initializeData.validatorTimelock;

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory batchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: _initializeData.genesisBatchHash,
            indexRepeatedStorageChanges: _initializeData.genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: _initializeData.genesisBatchCommitment
        });
        storedBatchZero = keccak256(abi.encode(batchZero));

        initialCutHash = keccak256(abi.encode(_initializeData.diamondCut));

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);
    }

    /// @notice Starts the transfer of admin rights. Only the current admin can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    function setPendingAdmin(address _newPendingAdmin) external onlyOwnerOrAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = pendingAdmin;
        // Change pending admin
        pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external {
        address currentPendingAdmin = pendingAdmin;
        require(msg.sender == currentPendingAdmin, "n42"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, currentPendingAdmin);
    }

    /// @dev set validatorTimelock. Cannot do it during initialization, as validatorTimelock is deployed after STM
    function setValidatorTimelock(address _validatorTimelock) external onlyOwnerOrAdmin {
        address oldValidatorTimelock = validatorTimelock;
        validatorTimelock = _validatorTimelock;
        emit NewValidatorTimelock(oldValidatorTimelock, _validatorTimelock);
    }

    /// @dev set initial cutHash
    function setInitialCutHash(Diamond.DiamondCutData calldata _diamondCut) external onlyOwner {
        bytes32 oldInitialCutHash = initialCutHash;
        bytes32 newCutHash = keccak256(abi.encode(_diamondCut));
        initialCutHash = newCutHash;
        emit NewInitialCutHash(oldInitialCutHash, newCutHash);
    }

    /// @dev set New Version with upgrade from old version
    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion
    ) external onlyOwner {
        bytes32 newCutHash = keccak256(abi.encode(_cutData));
        upgradeCutHash[_oldProtocolVersion] = newCutHash;
        uint256 previousProtocolVersion = protocolVersion;
        protocolVersion = _newProtocolVersion;
        emit NewProtocolVersion(previousProtocolVersion, _newProtocolVersion);
        emit NewUpgradeCutHash(_oldProtocolVersion, newCutHash);
    }

    /// @dev set upgrade for some protocolVersion
    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion
    ) external onlyOwner {
        bytes32 newCutHash = keccak256(abi.encode(_cutData));
        upgradeCutHash[_oldProtocolVersion] = newCutHash;
        emit NewUpgradeCutHash(_oldProtocolVersion, newCutHash);
    }

    /// @dev freezes the specified chain
    function freezeChain(uint256 _chainId) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).freezeDiamond();
    }

    /// @dev freezes the specified chain
    function unfreezeChain(uint256 _chainId) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).unfreezeDiamond();
    }

    /// @dev reverts batches on the specified chain
    function revertBatches(uint256 _chainId, uint256 _newLastBatch) external onlyOwnerOrAdmin {
        IZkSyncHyperchain(hyperchain[_chainId]).revertBatches(_newLastBatch);
    }

    /// @dev execute predefined upgrade
    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).upgradeChainFromVersion(_oldProtocolVersion, _diamondCut);
    }

    /// @dev executes upgrade on chain
    function executeUpgrade(uint256 _chainId, Diamond.DiamondCutData calldata _diamondCut) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).executeUpgrade(_diamondCut);
    }

    /// @dev setPriorityTxMaxGasLimit for the specified chain
    function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).setPriorityTxMaxGasLimit(_maxGasLimit);
    }

    /// @dev setTokenMultiplier for the specified chain
    function setTokenMultiplier(uint256 _chainId, uint128 _nominator, uint128 _denominator) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).setTokenMultiplier(_nominator, _denominator);
    }

    /// @dev changeFeeParams for the specified chain
    function changeFeeParams(uint256 _chainId, FeeParams calldata _newFeeParams) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).changeFeeParams(_newFeeParams);
    }

    /// @dev setValidator for the specified chain
    function setValidator(uint256 _chainId, address _validator, bool _active) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).setValidator(_validator, _active);
    }

    /// @dev setPorterAvailability for the specified chain
    function setPorterAvailability(uint256 _chainId, bool _zkPorterIsAvailable) external onlyOwner {
        IZkSyncHyperchain(hyperchain[_chainId]).setPorterAvailability(_zkPorterIsAvailable);
    }

    /// registration

    /// @dev we have to set the chainId at genesis, as blockhashzero is the same for all chains with the same chainId
    function _setChainIdUpgrade(uint256 _chainId, address _chainContract) internal {
        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setChainId, (_chainId));
        uint256[] memory uintEmptyArray;
        bytes[] memory bytesEmptyArray;

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR)),
            gasLimit: $(PRIORITY_TX_MAX_GAS_LIMIT),
            gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            maxFeePerGas: uint256(0),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the protocol version is used as "nonce" for system upgrade transactions
            nonce: protocolVersion,
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: systemContextCalldata,
            signature: new bytes(0),
            factoryDeps: uintEmptyArray,
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: bytesEmptyArray,
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            verifier: address(0),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });

        Diamond.FacetCut[] memory emptyArray;
        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: emptyArray,
            initAddress: genesisUpgrade,
            initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
        });

        IAdmin(_chainContract).executeUpgrade(cutData);
        emit SetChainIdUpgrade(_chainContract, l2ProtocolUpgradeTx, protocolVersion);
    }

    /// @dev used to register already deployed hyperchain contracts
    /// @param _chainId the chain's id
    /// @param _hyperchainContract the chain's contract
    function registerAlreadyDeployedHyperchain(uint256 _chainId, address _hyperchainContract) external onlyOwner {
        require(_hyperchainContract != address(0), "STM: hyperchain zero");
        hyperchain[_chainId] = _hyperchainContract;
        emit NewHyperchain(_chainId, _hyperchainContract);
    }

    /// @notice called by Bridgehub when a chain registers
    /// @param _chainId the chain's id
    /// @param _baseToken the base token address used to pay for gas fees
    /// @param _sharedBridge the shared bridge address, used as base token bridge
    /// @param _admin the chain's admin address
    /// @param _diamondCut the diamond cut data that initializes the chains Diamond Proxy
    function createNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes calldata _diamondCut
    ) external onlyBridgehub {
        if (hyperchain[_chainId] != address(0)) {
            // Hyperchain already registered
            return;
        }

        // check not registered
        Diamond.DiamondCutData memory diamondCut = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        // check input
        bytes32 cutHashInput = keccak256(_diamondCut);
        require(cutHashInput == initialCutHash, "STM: initial cutHash mismatch");

        // construct init data
        bytes memory initData;
        /// all together 4+9*32=292 bytes
        initData = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(_chainId),
            bytes32(uint256(uint160(bridgehub))),
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(protocolVersion)),
            bytes32(uint256(uint160(_admin))),
            bytes32(uint256(uint160(validatorTimelock))),
            bytes32(uint256(uint160(_baseToken))),
            bytes32(uint256(uint160(_sharedBridge))),
            bytes32(storedBatchZero),
            diamondCut.initCalldata
        );

        diamondCut.initCalldata = initData;
        // deploy hyperchainContract
        DiamondProxy hyperchainContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);

        // save data
        address hyperchainAddress = address(hyperchainContract);

        hyperchain[_chainId] = hyperchainAddress;

        // set chainId in VM
        _setChainIdUpgrade(_chainId, hyperchainAddress);

        emit NewHyperchain(_chainId, hyperchainAddress);
    }
}
