/*
MOASS - Mother Of All Short Squeezes

https://t.me/MOASS_Token

5% redistribution tax 
5% stocks fund tax 
3% liquidity tax 
1% charity tax
1% marketing tax 

10 second cooldown between transfers (buy/sell)
*/

// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.4;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.1.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.1.0/contracts/utils/Context.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.1.0/contracts/utils/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.1.0/contracts/utils/Address.sol";

contract MOASS is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;

    // erc20
    mapping (address => uint256) private _rOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    // total supply = 10 trillion
    uint256 private constant _tTotal = 10**13 * 10**_decimals;
    uint256 private constant MAX = ~uint256(0);
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    string private _name = 'MOASS';
    string private _symbol = 'MOASS';
    uint8 private constant _decimals = 9;

    // uniswap/ pancakeswap
    address public constant ROUTER_ADDR = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IUniswapV2Router02 public constant ROUTER = IUniswapV2Router02(ROUTER_ADDR);
    IERC20 public immutable WETH;
    address public constant FACTORY_ADDR = address(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    address public immutable PAIR_ADDR;
    address public immutable WETH_ADDR;
    address public immutable MY_ADDR;

    // cooldown
    mapping (address => uint256) public timeTransfer;
    bool private _cooldownEnabled = true;
    uint256 private _cooldown = 10 seconds;

    // taxes
    mapping (address => bool) public whitelist;
    struct Taxes {
        uint256 charity;
        uint256 redistribution;
        uint256 stocks;
        uint256 liquidity;
        uint256 marketing;
    }

    Taxes private _taxRates = Taxes(10, 50, 50, 30, 10);
    bool public taxesDisabled;
    address payable public stocksAddr = payable(0x4d2835AB2C35De22dEde516d3BCFCBdE0c4BE66c);
    address payable public charityAddr = payable(0xa74f01b239B0dAe269D3bc6B16666C0078d05fde);
    address payable public marketingAddr = payable(0x9080a0d9D6439c4A36a65f2e4CEeF4A65AD38B07);

    // gets set to true after openTrading is called, cannot be unset
    bool public tradingEnabled = false;
    // in case we want to turn the token in a standard erc20 token for various reasons, cannot be unset
    bool public isNormalToken = false;
    
    bool public swapEnabled = true;
    bool public inSwap = false;
    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    event SwapTokensForETH(uint256 amountIn, address[] path);
    event AddedLiquidity(uint256 amountEth, uint256 amountTokens);

    constructor () {
        PAIR_ADDR = UniswapV2Library.pairFor(FACTORY_ADDR, ROUTER.WETH(), address(this));
        WETH_ADDR = ROUTER.WETH();
        WETH = IERC20(IUniswapV2Router02(ROUTER).WETH());
        MY_ADDR = address(this);

        _rOwned[_msgSender()] = _rTotal;
        emit Transfer(address(0), _msgSender(), _rTotal);

        whitelist[address(this)] = true;
        whitelist[_msgSender()] = true;
        // not strictly necessary, but probably sensible
        whitelist[stocksAddr] = true;
        whitelist[charityAddr] = true;
    }
    receive() external payable {}

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() public pure override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 tAmount) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(tAmount > 0, "Transfer amount must be greater than zero");
        require(tradingEnabled || whitelist[sender] || whitelist[recipient], "Trading is not live yet. ");
        
        if (isNormalToken || inSwap || whitelist[sender] || whitelist[recipient]) {
            _tokenTransferWithoutFees(sender, recipient, tAmount);
            return;
        }
        
        // buys
        if (sender == PAIR_ADDR && recipient != ROUTER_ADDR) {

            if (_cooldownEnabled) {
                _checkCooldown(recipient);
            }
        }
        
        // sells
        if (recipient == PAIR_ADDR && sender != ROUTER_ADDR) {
            
            if (_cooldownEnabled) {
                _checkCooldown(sender);
            }
            
            if (swapEnabled) {
                _doTheSwap();
            }
        } 
        
        _tokenTransferWithFees(sender, recipient, tAmount);
    }
    
    
    function _checkCooldown(address addr) private {
        // enforce cooldown and note down time
        require(
            timeTransfer[addr].add(_cooldown) < block.timestamp,
            "Need to wait until next transfer. "
        );
        timeTransfer[addr] = block.timestamp;
    }
    
    function _doTheSwap() private {
        if (balanceOf(MY_ADDR) == 0) {
            return;
        }
        
        uint256 total = _taxRates.charity.add(_taxRates.stocks).add(_taxRates.liquidity).add(_taxRates.marketing);
        uint256 totalMinusLiq = total.sub(_taxRates.liquidity.div(2));
        uint256 toBeSwappedPerc = totalMinusLiq.mul(1000).div(total);
        
        uint256 liqEthPerc = _taxRates.liquidity.div(2).mul(1000).div(totalMinusLiq);
        uint256 charityEthPerc = _taxRates.charity.mul(1000).div(totalMinusLiq);
        uint256 stocksEthPerc = _taxRates.stocks.mul(1000).div(totalMinusLiq);
        
        swapTokensForETH(balanceOf(MY_ADDR).mul(toBeSwappedPerc).div(1000));
        
        uint256 ethForLiq = MY_ADDR.balance.mul(liqEthPerc).div(1000);
        uint256 ethForCharity = MY_ADDR.balance.mul(charityEthPerc).div(1000);
        uint256 ethForStocks = MY_ADDR.balance.mul(stocksEthPerc).div(1000);
        uint256 ethForMarketing = MY_ADDR.balance.sub(ethForLiq).sub(ethForCharity).sub(ethForStocks);
        
        if (ethForLiq != 0) {
            uint256 tokensForLiq = balanceOf(MY_ADDR);
            addLiquidity(tokensForLiq, ethForLiq);
            emit AddedLiquidity(tokensForLiq, ethForLiq);
        }
        charityAddr.transfer(ethForCharity);
        stocksAddr.transfer(ethForStocks);
        marketingAddr.transfer(ethForMarketing);
    }


    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        _approve(MY_ADDR, ROUTER_ADDR, tokenAmount);

        ROUTER.addLiquidityETH{value: ethAmount}(
            MY_ADDR,
            tokenAmount,
            0, 
            0, 
            owner(),
            block.timestamp
        );
    }

    function _tokenTransferWithoutFees(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate = _getRate();
        uint256 rAmount = tAmount.mul(currentRate);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rAmount);
        emit Transfer(sender, recipient, tAmount);
    }

    function _tokenTransferWithFees(address sender, address recipient, uint256 tAmount) private {
        uint256 currentRate = _getRate();
        uint256 rAmount = tAmount.mul(currentRate);

        // getting tax values
        Taxes memory tTaxValues = _getTTaxValues(tAmount, _taxRates);
        Taxes memory rTaxValues = _getRTaxValues(tTaxValues);

        uint256 rTransferAmount = _getTransferAmount(rAmount, rTaxValues);
        uint256 tTransferAmount = _getTransferAmount(tAmount, tTaxValues);

        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);

        _rOwned[MY_ADDR] = _rOwned[MY_ADDR].add(rTaxValues.charity).add(rTaxValues.stocks).add(rTaxValues.liquidity);
        _rTotal = _rTotal.sub(rTaxValues.redistribution);
        
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function swapTokensForETH(uint256 tokenAmount) private lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = MY_ADDR;
        path[1] = WETH_ADDR;

        _approve(MY_ADDR, ROUTER_ADDR, tokenAmount);

        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            payable(this),
            block.timestamp
        );

        emit SwapTokensForETH(tokenAmount, path);
    }

    function _getRate() private view returns(uint256) {
        return _rTotal.div(_tTotal);
    }

    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less or equal than total reflections");
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    function _getTTaxValues(uint256 amount, Taxes memory taxRates) private pure returns (Taxes memory) {
        Taxes memory taxValues;
        taxValues.redistribution = amount.div(1000).mul(taxRates.redistribution);
        taxValues.charity = amount.div(1000).mul(taxRates.charity);
        taxValues.stocks = amount.div(1000).mul(taxRates.stocks);
        taxValues.liquidity = amount.div(1000).mul(taxRates.liquidity);
        return taxValues;
    }

    function _getRTaxValues(Taxes memory tTaxValues) private view returns (Taxes memory) {
        Taxes memory taxValues;
        uint256 currentRate = _getRate();
        taxValues.redistribution = tTaxValues.redistribution.mul(currentRate);
        taxValues.charity = tTaxValues.charity.mul(currentRate);
        taxValues.stocks = tTaxValues.stocks.mul(currentRate);
        taxValues.liquidity = tTaxValues.liquidity.mul(currentRate);
        return taxValues;
    }

    function _getTransferAmount(uint256 amount, Taxes memory taxValues) private pure returns (uint256) {
        return amount.sub(taxValues.charity).sub(taxValues.liquidity).sub(taxValues.stocks).sub(taxValues.redistribution);
    }

    function openTrading() external onlyOwner() {
        tradingEnabled = true;
    }

    function manualTaxConv() external view onlyOwner() {
        _doTheSwap;
    }

    function setWhitelist(address addr, bool onoff) external onlyOwner() {
        whitelist[addr] = onoff;
    }

    function setCharityWallet(address payable charity) external onlyOwner() {
        charityAddr = charity;
    }

    function setStocksWallet(address payable stocks) external onlyOwner() {
        stocksAddr = stocks;
    }
    
    function setMarketingWallet(address payable marketing) external onlyOwner() {
        marketingAddr = marketing;
    }

    function setCooldownEnabled(bool onoff) external onlyOwner() {
        _cooldownEnabled = onoff;
    }
    
    function setTaxesDisabled(bool onoff) external onlyOwner() {
        taxesDisabled = onoff;
    }
    
    function setSwapEnabled(bool onoff) external onlyOwner() {
        swapEnabled = onoff;
    }
    
    function convertToStandardToken() external onlyOwner() {
        isNormalToken = true;
    }
}

library UniswapV2Library {
    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5' // init code hash
            )))));
    }
}

interface IUniswapV2Router02  {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}
