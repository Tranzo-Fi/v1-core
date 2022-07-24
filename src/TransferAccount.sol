// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.1;

import "./aave/FlashLoanReceiverBaseV2.sol";
import "./interfaces/ILendingPoolAddressesProviderV2.sol";
import "./interfaces/ILendingPoolV2.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
* @author @brotherlymite Harsh Pandey
* @title Tranzo smart contract
*/
contract TransferAccount is FlashLoanReceiverBaseV2, Withdrawable {
    using SafeMath for uint256;
    uint256 private s_platformFee;

    constructor(address _addressProvider, uint256 _platformFee)
        FlashLoanReceiverBaseV2(_addressProvider)
    {
        s_platformFee = _platformFee;
    }

    struct DebtTokenBalance {
        address tokenAddress;
        uint256 stableDebtTokenBalance;
        uint256 variableDebtTokenBalance;
    }

    struct aTokenBalance {
        address Token;
        address aTokenAddress;
        uint256 aTokenBalance;
    }

    /**
     * @dev This function must be called only be the LENDING_POOL and takes care of repaying
     * active debt positions, migrating collateral and incurring new V2 debt token debt.
     *
     * @param assets The array of flash loaned assets used to repay debts.
     * @param amounts The array of flash loaned asset amounts used to repay debts.
     * @param premiums The array of premiums incurred as additional debts.
     * @param initiator The address that initiated the flash loan, unused.
     * @param params The byte array containing, in this case, its contains the encoded params of transferAccount
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {

        (address _sender, address _recipient, DebtTokenBalance[] memory _DebtTokenBalance, aTokenBalance[] memory _aTokenBalance) = abi.decode(params, (address, address, DebtTokenBalance[], aTokenBalance[]));
        
        // Approve and Repay all Debt of sender
        for(uint i=0; i<_DebtTokenBalance.length; i++) {
            // Repay StableDebt
            if (_DebtTokenBalance[i].stableDebtTokenBalance != 0) {
                IERC20(_DebtTokenBalance[i].tokenAddress).approve(address(LENDING_POOL), _DebtTokenBalance[i].stableDebtTokenBalance);
                LENDING_POOL.repay(_DebtTokenBalance[i].tokenAddress, _DebtTokenBalance[i].stableDebtTokenBalance, 1, _sender);
            }
            // Repay VariableDebt
            if (_DebtTokenBalance[i].variableDebtTokenBalance != 0) {
                IERC20(_DebtTokenBalance[i].tokenAddress).approve(address(LENDING_POOL), _DebtTokenBalance[i].variableDebtTokenBalance);
                LENDING_POOL.repay(_DebtTokenBalance[i].tokenAddress, _DebtTokenBalance[i].variableDebtTokenBalance, 2, _sender);
            }
        }

        // Transfer all aTokens from sender to recipient
        for (uint i=0; i<_aTokenBalance.length; i++) {
            IERC20(_aTokenBalance[i].aTokenAddress).transferFrom(_sender, _recipient, _aTokenBalance[i].aTokenBalance);
        }
        
        // Borrow all DebtTokens from recipient + Flash Loan premium + Platform Fees
        for(uint i=0; i<_DebtTokenBalance.length; i++) {
            bool flag = false;
            // Borrow StableDebt
            if (_DebtTokenBalance[i].stableDebtTokenBalance != 0) {
                uint256 totalStableDebtTokenFee = premiums[i].add(calculatePlatformFee(_DebtTokenBalance[i].stableDebtTokenBalance));
                LENDING_POOL.borrow(
                    _DebtTokenBalance[i].tokenAddress,
                    _DebtTokenBalance[i].stableDebtTokenBalance.add(totalStableDebtTokenFee),
                    1,
                    0, 
                    _recipient
                );
                if (s_platformFee != 0) IERC20(_DebtTokenBalance[i].tokenAddress).transfer(owner(), calculatePlatformFee(_DebtTokenBalance[i].stableDebtTokenBalance));
                flag = true;
            }
            // Borrow VariableDebt
            if (_DebtTokenBalance[i].variableDebtTokenBalance != 0) {
                uint256 borrowAmount;
                if (flag == true) {
                    // Flash Loan Premium already borrowed
                    borrowAmount = _DebtTokenBalance[i].variableDebtTokenBalance;
                } else {
                    // Flash Loan Premium not borrowed
                    uint256 totalVariableDebtTokenFee = premiums[i].add(calculatePlatformFee(_DebtTokenBalance[i].variableDebtTokenBalance));
                    borrowAmount = _DebtTokenBalance[i].variableDebtTokenBalance.add(totalVariableDebtTokenFee);
                }
                LENDING_POOL.borrow(_DebtTokenBalance[i].tokenAddress, borrowAmount, 2, 0, _recipient);
                if (flag == false && s_platformFee != 0) IERC20(_DebtTokenBalance[i].tokenAddress).transfer(owner(), calculatePlatformFee(_DebtTokenBalance[i].variableDebtTokenBalance));
            }
        }

        // Approve the LendingPool contract allowance to *pull* the owed amount
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amountOwing = amounts[i].add(premiums[i]);
            IERC20(assets[i]).approve(address(LENDING_POOL), amountOwing);
        }

        return true;
    }

    /**
     * @dev Calculates the platform fees to be paid by user
     * @param amount The amount of debt token for which the fee has to be paid to the platform
     * @return The platform fee to be paid in wei
     */
    function calculatePlatformFee(uint256 amount) private view returns(uint256) {
        if (s_platformFee == 0) return 0;
        return (amount.mul(s_platformFee)).div(10000);
    }

    /**
     * @dev This function is to be called only by the owner which changes the platform fee
     * @param _fee The new fee for the platform
     */
    function changePlatformFee(uint256 _fee) external onlyOwner {
        s_platformFee = _fee;
    }

    function _flashloan(address[] memory assets, uint256[] memory amounts, bytes memory _params)
        internal
    {
        address receiverAddress = address(this);

        address onBehalfOf = address(this);
        bytes memory params = _params;
        uint16 referralCode = 0;

        uint256[] memory modes = new uint256[](assets.length);

        // 0 = no debt (flash), 1 = stable, 2 = variable
        for (uint256 i = 0; i < assets.length; i++) {
            modes[i] = 0;
        }

        LENDING_POOL.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
    }

    /**
     * @dev Migrates AAVE V2 positions from sender to recipient by taking a flashloan
     * @param _recipientAccount Address of the recipient to which the sender wants to migrate his positions to
     * @param _DebtTokenBalance Contains all the Debt balances of the sender
     * @param _aTokenBalance Contains all the balances of Collateral of the sender
     */
    function transferAccount(
        address _recipientAccount,
        DebtTokenBalance[] memory _DebtTokenBalance,
        aTokenBalance[] memory _aTokenBalance
    ) external {
        require(_recipientAccount != msg.sender, "Invalid recipient address");
        bytes memory params = abi.encode(msg.sender, _recipientAccount, _DebtTokenBalance, _aTokenBalance);
        address[] memory assets = new address[](_DebtTokenBalance.length);
        uint256[] memory amounts = new uint256[](_DebtTokenBalance.length);

        // Flash Loan all the borrowed assets
        for (uint i=0; i<_DebtTokenBalance.length; i++) {
            assets[i] = _DebtTokenBalance[i].tokenAddress;
            amounts[i] = (_DebtTokenBalance[i].stableDebtTokenBalance).add(_DebtTokenBalance[i].variableDebtTokenBalance);
        }
        _flashloan(assets, amounts, params);
    }
}
