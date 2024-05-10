// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {AccessControl} from '@openzeppelin/access/AccessControl.sol';
import {IERC20} from '@openzeppelin/token/ERC20/ERC20.sol';
import {ISAFEEngine} from '@opendollar/contracts/SAFEEngine.sol';
import {IOracleRelayer} from '@opendollar/interfaces/IOracleRelayer.sol';
import {IDelayedOracle} from '@opendollar/interfaces/oracles/IDelayedOracle.sol';
import {ICollateralJoinFactory} from '@opendollar/interfaces/factories/ICollateralJoinFactory.sol';
import {ICollateralJoin} from '@opendollar/interfaces/utils/ICollateralJoin.sol';
import {IVault721} from '@opendollar/interfaces/proxies/IVault721.sol';
import {IODSaviour} from '../interfaces/IODSaviour.sol';
import {ODSafeManager, IODSafeManager} from '@opendollar/contracts/proxies/ODSafeManager.sol';
import {Math} from '@opendollar/libraries/Math.sol';
import {Assertions} from '@opendollar/libraries/Assertions.sol';

/**
 * @notice Steps to save a safe using ODSaviour:
 *
 * 1. Protocol DAO => connect [this] saviour `LiquidationEngine.connectSAFESaviour`
 * 2. Treasury DAO => enable specific vaults `ODSaviour.setVaultStatus`
 * 3. Treasury DAO => approve `ERC20.approveTransferFrom` to the saviour
 * 4. Vault owner => protect thier safe with elected saviour `LiquidationEngine.protectSAFE` (only works if ARB DAO enable vaultId)
 * 5. Safe in liquidation => auto call `LiquidationEngine.attemptSave` gets saviour from chosenSAFESaviour mapping
 * 6. Saviour => increases collateral `ODSaviour.saveSAFE`
 */
contract ODSaviour is AccessControl, IODSaviour {
  using Math for uint256;
  using Assertions for address;

  //solhint-disable-next-line modifier-name-mixedcase
  bytes32 public constant SAVIOUR_TREASURY = keccak256(abi.encode('SAVIOUR_TREASURY'));
  bytes32 public constant PROTOCOL = keccak256(abi.encode('PROTOCOL'));

  address public saviourTreasury;
  address public protocolGovernor;
  address public liquidationEngine;

  IVault721 public vault721;
  IOracleRelayer public oracleRelayer;
  IODSafeManager public safeManager;
  ISAFEEngine public safeEngine;
  ICollateralJoinFactory public collateralJoinFactory;

  mapping(uint256 _vaultId => bool _enabled) private _enabledVaults;
  mapping(bytes32 _cType => IERC20 _tokenAddress) private _saviourTokenAddresses;

  /**
   * @param _init The SaviourInit struct;
   */
  constructor(SaviourInit memory _init) {
    saviourTreasury = _init.saviourTreasury.assertNonNull();
    protocolGovernor = _init.protocolGovernor.assertNonNull();
    vault721 = IVault721(_init.vault721.assertNonNull());
    oracleRelayer = IOracleRelayer(_init.oracleRelayer.assertNonNull());
    safeManager = IODSafeManager(address(vault721.safeManager()).assertNonNull());
    liquidationEngine = ODSafeManager(address(safeManager)).liquidationEngine().assertNonNull(); // todo update @opendollar package to include `liquidationEngine` - PR #693
    collateralJoinFactory = ICollateralJoinFactory(_init.collateralJoinFactory.assertNonNull());
    safeEngine = ISAFEEngine(address(safeManager.safeEngine()).assertNonNull());

    if (_init.saviourTokens.length != _init.cTypes.length) revert LengthMismatch();

    for (uint256 i; i < _init.cTypes.length; i++) {
      _saviourTokenAddresses[_init.cTypes[i]] = IERC20(_init.saviourTokens[i].assertNonNull());
    }
    _setupRole(SAVIOUR_TREASURY, saviourTreasury);
    _setupRole(PROTOCOL, protocolGovernor);
    _setupRole(PROTOCOL, liquidationEngine);
  }

  function isEnabled(uint256 _vaultId) external view returns (bool _enabled) {
    _enabled = _enabledVaults[_vaultId];
  }

  function addCType(bytes32 _cType, address _tokenAddress) external onlyRole(SAVIOUR_TREASURY) {
    _saviourTokenAddresses[_cType] = IERC20(_tokenAddress);
    emit CollateralTypeAdded(_cType, _tokenAddress);
  }

  /**
   * @dev
   */
  function setVaultStatus(uint256 _vaultId, bool _enabled) external onlyRole(SAVIOUR_TREASURY) {
    _enabledVaults[_vaultId] = _enabled;

    emit VaultStatusSet(_vaultId, _enabled);
  }

  /**
   * todo increase collateral to sufficient level
   * 1. find out how much collateral is required to effectively save the safe
   * 2. transfer the collateral to the vault, so the liquidation math will result in null liquidation
   * 3. write tests
   */
  function saveSAFE(
    address _liquidator,
    bytes32 _cType,
    address _safe
  ) external onlyRole(PROTOCOL) returns (bool _ok, uint256 _collateralAdded, uint256 _liquidatorReward) {
    uint256 vaultId = safeManager.safeHandlerToSafeId(_safe);
    if (!_enabledVaults[vaultId]) revert VaultNotAllowed(vaultId);

    IOracleRelayer.OracleRelayerCollateralParams memory oracleParams = oracleRelayer.cParams(_cType);
    IDelayedOracle oracle = oracleParams.oracle;

    uint256 reqCollateral;

    {
      (uint256 currCollateral, uint256 currDebt) = _getCurrentCollateralAndDebt(_cType, _safe);
      uint256 accumulatedRate = safeEngine.cData(_cType).accumulatedRate;

      uint256 currCRatio = ((currCollateral.wmul(oracle.read())).wdiv(currDebt.wmul(accumulatedRate))) / 1e7;
      uint256 safetyCRatio = oracleParams.safetyCRatio / 10e24;
      uint256 diffCRatio = safetyCRatio.wdiv(currCRatio);

      reqCollateral = (currCollateral.wmul(diffCRatio)) - currCollateral;
    }

    // transferFrom ARB Treasury amount of reqCollateral
    _saviourTokenAddresses[_cType].transferFrom(saviourTreasury, address(this), reqCollateral);

    if (_saviourTokenAddresses[_cType].balanceOf(address(this)) == reqCollateral) {
      address collateralJoin = collateralJoinFactory.collateralJoins(_cType);
      ICollateralJoin(collateralJoin).join(_safe, reqCollateral);
      emit SafeSaved(vaultId, reqCollateral);
      _ok = true;
    } else {
      _ok = false;
      revert CollateralTransferFailed();
    }
    /**
     * todo
     * 1. CollateralJoin call `join` with safeHandler + reqCollateral
     */
    _collateralAdded = type(uint256).max;
    _liquidatorReward = type(uint256).max;
  }

  function _getCurrentCollateralAndDebt(
    bytes32 _cType,
    address _safe
  ) internal returns (uint256 currCollateral, uint256 currDebt) {
    ISAFEEngine.SAFE memory SafeEngineData = safeEngine.safes(_cType, _safe);
    currCollateral = SafeEngineData.lockedCollateral;
    currDebt = SafeEngineData.generatedDebt;
  }
}
