// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../multiSignature/multiSignatureClient.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

/**
 * @dev Collection of functions related to the address type
 */
/* ============================================================================
 * 【学习注释 · 文件总览】AddressPrivileges —— 铸币权限白名单（75 行）
 *
 * 作用一句话：维护一个"谁可以 mint/burn 凭证"的地址集合（EnumerableSet），
 * 只有白名单成员能过 onlyMinter 检查。部署后把 PledgePool 主合约加进来，
 * 这样 sp/jp 的铸销权就锁死在主合约手里。
 *
 * 权限体系串起来看（三张合约的 validCall/onlyMinter 都指向同一个多签合约）：
 *   multiSignature（最高权）→ validCall（settle/finish/setPrice 等敏感操作）
 *                          → addMinter（发白名单）→ onlyMinter（mint/burn 凭证）
 * 读任何函数先问一句：这个函数挂着哪个权限修饰器？谁能调？——权限是审计第一课。
 * ==========================================================================*/
contract AddressPrivileges is multiSignatureClient {

    constructor(address multiSignature) multiSignatureClient(multiSignature) public {
    }

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _minters;

    /**
      * @notice add a minter
      * @dev function to add a minter for an asset
      * @param _addMinter add a  minter address
      # @return true or false
      */
    function addMinter(address _addMinter) public validCall returns (bool) {
        require(_addMinter != address(0), "Token: _addMinter is the zero address");
        return EnumerableSet.add(_minters, _addMinter);
    }

    /**
      * @notice delete a minter
      * @dev function to delete a minter for an asset
      * @param _delMinter delete a minter address
      # @return true or false
      */
    function delMinter(address _delMinter) public validCall returns (bool) {
        require(_delMinter != address(0), "Token: _delMinter is the zero address");
        return EnumerableSet.remove(_minters, _delMinter);
    }

    /**
      * @notice get minter list length
      * @dev function to get the minter list length
      # @return the lenght of minter list
      */
    function getMinterLength() public view returns (uint256) {
        return EnumerableSet.length(_minters);
    }

    /**
      * @notice Determine if this address is minter
      * @dev function to judge address
      * @param account is a condition
      # @return true or false
      */
    function isMinter(address account) public view returns (bool) {
        return EnumerableSet.contains(_minters, account);
    }

     /**
      * @notice Get minter account according to index
      * @dev function to get minter account
      * @param _index of index
      # @return  a minter account
      */
    function getMinter(uint256 _index) public view  returns (address){
        require(_index <= getMinterLength() - 1, "Token: index out of bounds");
        return EnumerableSet.at(_minters, _index);
    }

    modifier onlyMinter() {
        require(isMinter(msg.sender), "Token: caller is not the minter");
        _;
    }

}