// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./AddressPrivileges.sol";


/* ============================================================================
 * 【学习注释 · 文件总览】DebtToken.sol —— sp/jp 凭证代币（38 行，极简但有讲究）
 *
 * Pledge 池子里两种凭证都是这个合约的实例：
 *   spCoin（放款凭证）：claimLend 时 mint，withdrawLend 时 burn，burn 份额=分钱份额
 *   jpCoin（借款欠条）：claimBorrow 时 mint（数量=应还抵押物量），withdrawBorrow 时 burn
 *
 * 安全核心只有一件事：mint/burn 只允许 onlyMinter（AddressPrivileges 管理，
 * 实际就是 PledgePool 主合约）——凭证的发行权必须收在主合约手里，
 * 否则任何人都能 mint spToken 白嫖放款份额。
 *
 * 阅读问题自测：为什么 burn 可以指定 _from？→ 主合约调用时从用户账上销毁，
 * 用户必须先 approve 给主合约（对照 withdrawLend/Borrow 的调用方式）。
 * ==========================================================================*/

contract DebtToken is ERC20, AddressPrivileges {

    constructor(string memory _name, string memory _symbol, address multiSignature) public ERC20(_name, _symbol) AddressPrivileges(multiSignature) {
    }

    /**
      * @notice mint the token
      * @dev function to mint token for an asset
      * @param _to means receiving address
      * @param _amount means mint amount
      # @return true is success
      */
    function mint(address _to, uint256 _amount) public onlyMinter returns (bool) {
        _mint(_to, _amount);
        return true;
    }

    /**
      * @notice burn the token
      * @dev function to burn token for an asset
      * @param _from means destory address
      * @param _amount means destory amount
      # @return true is success
      */
    function burn(address _from,uint256 _amount) public onlyMinter returns (bool) {
        _burn(_from, _amount);
        return true;
    }

}
