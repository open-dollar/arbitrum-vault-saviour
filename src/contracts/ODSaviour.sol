// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

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
import {Authorizable} from '@opendollar/contracts/utils/Authorizable.sol';
import {Modifiable} from '@opendollar/contracts/utils/Modifiable.sol';
import {ModifiablePerCollateral} from '@opendollar/contracts/utils/ModifiablePerCollateral.sol';

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
contract ODSaviour is Authorizable, Modifiable, ModifiablePerCollateral, IODSaviour {
  using Math for uint256;
  using Assertions for address;

  uint256 public liquidatorReward;
  address public saviourTreasury;
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
  constructor(SaviourInit memory _init) Authorizable(msg.sender) {
    vault721 = IVault721(_init.vault721.assertNonNull());
    oracleRelayer = IOracleRelayer(_init.oracleRelayer.assertNonNull());
    safeManager = IODSafeManager(address(vault721.safeManager()));
    liquidationEngine = ODSafeManager(address(safeManager)).liquidationEngine(); // todo update @opendollar package to include `liquidationEngine` - PR #693
    collateralJoinFactory = ICollateralJoinFactory(_init.collateralJoinFactory.assertNonNull());
    safeEngine = ISAFEEngine(address(safeManager.safeEngine()));
  }

  function isEnabled(uint256 _vaultId) external view returns (bool _enabled) {
    _enabled = _enabledVaults[_vaultId];
  }

  function cType(bytes32 _cType) public view returns (address _tokenAddress) {
    return address(_saviourTokenAddresses[_cType]);
  }

  function saveSAFE(
    address _liquidator,
    bytes32 _cType,
    address _safe
  ) external returns (bool _ok, uint256 _collateralAdded, uint256 _liquidatorReward) {
    if (liquidationEngine != msg.sender) revert OnlyLiquidationEngine();
    uint256 _vaultId = safeManager.safeHandlerToSafeId(_safe);
    if (_vaultId == 0) {
      _collateralAdded = type(uint256).max;
      _liquidatorReward = type(uint256).max;
      _ok = true;
      return (_ok, _collateralAdded, _liquidatorReward);
    }
    if (!_enabledVaults[_vaultId]) revert VaultNotAllowed(_vaultId);

    uint256 _reqCollateral;
    {
      ISAFEEngine.SAFEEngineCollateralData memory _safeEngCData = safeEngine.cData(_cType);

      (uint256 _currCollateral, uint256 _currDebt) = getCurrentCollateralAndDebt(_cType, _safe);
      uint256 _accumulatedRate = _safeEngCData.accumulatedRate;
      uint256 _liquidationPrice = _safeEngCData.liquidationPrice;
      uint256 _safetyPrice = _safeEngCData.safetyPrice;

      uint256 _collatXliqPrice = _currCollateral.wmul(_liquidationPrice);
      uint256 _debtXaccumuRate = _currDebt.wmul(_accumulatedRate);

      _reqCollateral = (_debtXaccumuRate - _collatXliqPrice).wdiv(_safetyPrice);
      uint256 _newCollatXliqPrice = (_reqCollateral + _currCollateral).wmul(_liquidationPrice);

      if (_newCollatXliqPrice <= _debtXaccumuRate) revert SafetyRatioNotMet();
    }
    IERC20 _token = _saviourTokenAddresses[_cType];
    _token.transferFrom(saviourTreasury, address(this), _reqCollateral);

    if (_token.balanceOf(address(this)) >= _reqCollateral) {
      address _collateralJoin = collateralJoinFactory.collateralJoins(_cType);
      _token.approve(_collateralJoin, _reqCollateral);
      ICollateralJoin(_collateralJoin).join(_safe, _reqCollateral);
      safeManager.modifySAFECollateralization(_vaultId, int256(_reqCollateral), int256(0), false);
      _collateralAdded = _reqCollateral;
      _liquidatorReward = liquidatorReward;

      emit SafeSaved(_vaultId, _reqCollateral);
      _ok = true;
    } else {
      _ok = false;
      revert CollateralTransferFailed();
    }
  }

  function getCurrentCollateralAndDebt(
    bytes32 _cType,
    address _safe
  ) public view returns (uint256 _currCollateral, uint256 _currDebt) {
    ISAFEEngine.SAFE memory _safeData = safeEngine.safes(_cType, _safe);
    _currCollateral = _safeData.lockedCollateral;
    _currDebt = _safeData.generatedDebt;
  }

  function _initializeCollateralType(bytes32 _cType, bytes memory _collateralParams) internal virtual override {
    if (address(_saviourTokenAddresses[_cType]) != address(0)) revert AlreadyInitialized(_cType);
    address saviourTokenAddress = abi.decode(_collateralParams, (address));
    _saviourTokenAddresses[_cType] = IERC20(saviourTokenAddress);
  }

  function _modifyParameters(bytes32 _cType, bytes32 _param, bytes memory _data) internal virtual override {
    if (_param == 'saviourToken') {
      if (address(_saviourTokenAddresses[_cType]) == address(0)) revert CollateralMustBeInitialized(_cType);
      address newToken = abi.decode(_data, (address));
      _saviourTokenAddresses[_cType] = IERC20(newToken);
    } else {
      revert UnrecognizedParam();
    }
  }

  function _modifyParameters(bytes32 _param, bytes memory _data) internal virtual override {
    if (_param == 'setVaultStatus') {
      (uint256 vaultId, bool enabled) = abi.decode(_data, (uint256, bool));
      bytes32 collateralType = safeManager.safeData(vaultId).collateralType;
      if (address(_saviourTokenAddresses[collateralType]) == address(0)) revert UninitializedCollateral(collateralType);
      _enabledVaults[vaultId] = enabled;
    } else if (_param == 'liquidatorReward') {
      uint256 _liquidatorReward = abi.decode(_data, (uint256));
      liquidatorReward = _liquidatorReward;
    } else if (_param == 'saviourTreasury') {
      if (saviourTreasury != address(0)) {
        _removeAuthorization(saviourTreasury);
      }
      saviourTreasury = abi.decode(_data, (address));
      _addAuthorization(saviourTreasury);
    } else {
      revert UnrecognizedParam();
    }
  }
}
