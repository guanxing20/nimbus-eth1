# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/math,
  eth/common/keys,
  results,
  unittest2,
  chronos,
  ../hive_integration/nodocker/engine/tx_sender,
  ../hive_integration/nodocker/engine/cancun/blobs,
  ../execution_chain/db/ledger,
  ../execution_chain/core/chain,
  ../execution_chain/core/eip4844,
  ../execution_chain/[config, transaction, constants],
  ../execution_chain/core/tx_pool,
  ../execution_chain/core/tx_pool/tx_desc,
  ../execution_chain/core/pooled_txs,
  ../execution_chain/common/common,
  ../execution_chain/utils/utils,
  ./macro_assembler

const
  genesisFile = "tests/customgenesis/merge.json"
  feeRecipient = address"0000000000000000000000000000000000000212"
  recipient = address"0000000000000000000000000000000000000213"
  recipient214 = address"0000000000000000000000000000000000000214"
  prevRandao = Bytes32 EMPTY_UNCLE_HASH
  contractCode = evmByteCode:
    PrevRandao   # VAL
    Push1 "0x11" # KEY
    Sstore       # OP
    Stop
  slot = 0x11.u256
  amount = 1000.u256
  withdrawalTriggerContract = address"00000961Ef480Eb55e80D19ad83579A64c007002"
  consolidationWithdrawalTrigger = address"0000BBdDc7CE488642fb579F8B00f3a590007251"
  triggerCode = hexToSeqByte(
    "0x3373fffffffffffffffffffffffffffffffffffffffe1460cb5760115f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff146101f457600182026001905f5b5f82111560685781019083028483029004916001019190604d565b909390049250505036603814608857366101f457346101f4575f5260205ff35b34106101f457600154600101600155600354806003026004013381556001015f35815560010160203590553360601b5f5260385f601437604c5fa0600101600355005b6003546002548082038060101160df575060105b5f5b8181146101835782810160030260040181604c02815460601b8152601401816001015481526020019060020154807fffffffffffffffffffffffffffffffff00000000000000000000000000000000168252906010019060401c908160381c81600701538160301c81600601538160281c81600501538160201c81600401538160181c81600301538160101c81600201538160081c81600101535360010160e1565b910180921461019557906002556101a0565b90505f6002555f6003555b5f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff14156101cd57505f5b6001546002828201116101e25750505f6101e8565b01600290035b5f555f600155604c025ff35b5f5ffd"
  )

type
  TestEnv = object
    conf  : NimbusConf
    com   : CommonRef
    chain : ForkedChainRef
    xp    : TxPoolRef
    sender: TxSender

  CustomTx = CustomTransactionData

proc initConf(envFork: HardFork): NimbusConf =
  var conf = makeConfig(
    @["--custom-network:" & genesisFile]
  )

  doAssert envFork >= MergeFork

  let cc = conf.networkParams.config
  if envFork >= MergeFork:
    cc.mergeNetsplitBlock = Opt.some(0'u64)

  if envFork >= Shanghai:
    cc.shanghaiTime = Opt.some(0.EthTime)

  if envFork >= Cancun:
    cc.cancunTime = Opt.some(0.EthTime)

  if envFork >= Prague:
    cc.pragueTime = Opt.some(0.EthTime)
    conf.networkParams.genesis.alloc[withdrawalTriggerContract] = GenesisAccount(
      balance: 0.u256,
      code: triggerCode
    )
    conf.networkParams.genesis.alloc[consolidationWithdrawalTrigger] = GenesisAccount(
      balance: 0.u256,
      code: triggerCode
    )

  if envFork >= Osaka:
    cc.osakaTime = Opt.some(0.EthTime)

  conf.networkParams.genesis.alloc[recipient] = GenesisAccount(code: contractCode)
  conf

proc initEnv(conf: NimbusConf): TestEnv =
  let
    # create the sender first, because it will modify networkParams
    sender = TxSender.new(conf.networkParams, 30)
    com    = CommonRef.new(newCoreDbRef DefaultDbMemory,
               nil, conf.networkId, conf.networkParams)
    chain  = ForkedChainRef.init(com)

  TestEnv(
    conf  : conf,
    com   : com,
    chain : chain,
    xp    : TxPoolRef.new(chain),
    sender: sender
  )

proc initEnv(envFork: HardFork): TestEnv =
  let conf = initConf(envFork)
  initEnv(conf)

template checkAddTx(xp, tx, errorCode) =
  let prevCount = xp.len
  let rc = xp.addTx(tx)
  check rc.isErr == true
  if rc.isErr:
    check rc.error == errorCode
  check xp.len == prevCount

template checkAddTx(xp, tx) =
  let expCount = xp.len + 1
  let rc = xp.addTx(tx)
  check rc.isOk == true
  if rc.isErr:
    debugEcho "ADD TX: ", rc.error
  check xp.len == expCount

template checkAddTxSupersede(xp, tx) =
  let prevCount = xp.len
  let rc = xp.addTx(tx)
  check rc.isOk == true
  if rc.isErr:
    debugEcho "ADD TX SUPERSEDE: ", rc.error
  check xp.len == prevCount

template checkAssembleBlock(xp, expCount): auto =
  xp.timestamp = xp.timestamp + 1
  let rc = xp.assembleBlock()
  check rc.isOk == true
  if rc.isErr:
    debugEcho "ASSEMBLE BLOCK: ", rc.error
  if rc.isOk:
    check rc.value.blk.transactions.len == expCount
  rc.get

template checkImportBlock(xp: TxPoolRef, bundle: AssembledBlock) =
  let rc = waitFor xp.chain.importBlock(bundle.blk)
  check rc.isOk == true
  if rc.isErr:
    debugEcho "IMPORT BLOCK: ", rc.error

template checkImportBlock(xp: TxPoolRef, expCount: int, expRem: int) =
  let bundle = checkAssembleBlock(xp, expCount)
  checkImportBlock(xp, bundle)
  xp.removeNewBlockTxs(bundle.blk)
  check xp.len == expRem

template checkImportBlock(xp: TxPoolRef, expCount: int) =
  let bundle = checkAssembleBlock(xp, expCount)
  checkImportBlock(xp, bundle)

template checkImportBlock(xp: TxPoolRef, bundle: AssembledBlock, expRem: int) =
  checkImportBlock(xp, bundle)
  xp.removeNewBlockTxs(bundle.blk)
  check xp.len == expRem

proc createPooledTransactionWithBlob(
    mx: TxSender,
    acc: TestAccount,
    recipient: Address,
    amount: UInt256,
    nonce: AccountNonce
): PooledTransaction =
  # Create the transaction
  let
    tc = BlobTx(
      recipient: Opt.some(recipient),
      gasLimit: 100000.GasInt,
      gasTip: GasInt(10 ^ 9),
      gasFee: GasInt(10 ^ 9),
      blobGasFee: u256(1),
      blobCount: 1,
      blobID: 1,
    )

  let params = MakeTxParams(
    chainId: mx.chainId,
    key: acc.key,
    nonce: nonce,
  )

  makeTx(params, tc)

proc createPooledTransactionWithBlob7594(
    mx: TxSender,
    acc: TestAccount,
    recipient: Address,
    amount: UInt256,
    nonce: AccountNonce
): PooledTransaction =
  # Create the transaction
  let
    tc = BlobTx7594(
      recipient: Opt.some(recipient),
      gasLimit: 100000.GasInt,
      gasTip: GasInt(10 ^ 9),
      gasFee: GasInt(10 ^ 9),
      blobGasFee: u256(1),
      blobCount: 1,
      blobID: 2,
    )

  let params = MakeTxParams(
    chainId: mx.chainId,
    key: acc.key,
    nonce: nonce,
  )

  makeTx(params, tc)

proc makeTx(
  mx: TxSender,
  acc: TestAccount,
  recipient: Address,
  amount: UInt256,
  nonce: AccountNonce): PooledTransaction =
  let
    tc = BaseTx(
      gasLimit: 75000,
      recipient: Opt.some(recipient),
      amount: amount,
    )
  mx.makeTx(tc, acc, nonce)

suite "TxPool test suite":
  let
    env = initEnv(Cancun)
    xp = env.xp
    mx = env.sender
    chain = env.chain

  xp.prevRandao = prevRandao
  xp.feeRecipient = feeRecipient
  xp.timestamp = EthTime.now()

  test "Bad blob tx":
    let acc = mx.getAccount(7)
    let tc = BlobTx(
      txType: Opt.some(TxEip4844),
      gasLimit: 75000,
      recipient: Opt.some(acc.address),
      blobID: 0.BlobID
    )
    var ptx = mx.makeTx(tc, 0)
    var z = ptx.blobsBundle.blobs[0].bytes
    z[0] = not z[0]
    ptx.blobsBundle.blobs[0] = KzgBlob z
    xp.checkAddTx(ptx, txErrorInvalidBlob)

  test "Bad chainId":
    let acc = mx.getAccount(1)
    let tc = BaseTx(
      gasLimit: 75000
    )
    var ptx = mx.makeTx(tc, 0)
    let ccid = ptx.tx.chainId
    let cid = Opt.some(ccid.not)
    ptx.tx = mx.customizeTransaction(acc, ptx.tx, CustomTx(chainId: cid))
    xp.checkAddTx(ptx, txErrorChainIdMismatch)

  test "Basic validation error, gas limit too low":
    let tc = BaseTx(
      gasLimit: 18000
    )
    let ptx = mx.makeTx(tc, 0)
    xp.checkAddTx(ptx, txErrorBasicValidation)

  test "Known tx":
    let tc = BaseTx(
      gasLimit: 75000
    )
    let ptx = mx.makeNextTx(tc)
    xp.checkAddTx(ptx)
    xp.checkAddTx(ptx, txErrorAlreadyKnown)
    xp.checkImportBlock(1, 0)

  test "nonce too small":
    let tc = BaseTx(
      gasLimit: 75000
    )
    let ptx = mx.makeNextTx(tc)
    xp.checkAddTx(ptx)
    xp.checkImportBlock(1, 0)
    xp.checkAddTx(ptx, txErrorNonceTooSmall)

  test "nonce gap after account nonce":
    let acc = mx.getAccount(13)
    let tc = BaseTx(
      gasLimit: 75000
    )
    let ptx1 = mx.makeTx(tc, acc, 1)
    xp.checkAddTx(ptx1)

    xp.checkImportBlock(0)

    let ptx0 = mx.makeTx(tc, acc, 0)
    xp.checkAddTx(ptx0)

    xp.checkImportBlock(2, 0)

  test "nonce gap in the middle of nonces":
    let acc = mx.getAccount(14)
    let tc = BaseTx(
      gasLimit: 75000
    )

    let ptx0 = mx.makeTx(tc, acc, 0)
    xp.checkAddTx(ptx0)

    let ptx2 = mx.makeTx(tc, acc, 2)
    xp.checkAddTx(ptx2)

    xp.checkImportBlock(1, 1)

    let ptx1 = mx.makeTx(tc, acc, 1)
    xp.checkAddTx(ptx1)

    xp.checkImportBlock(2, 0)

  test "supersede existing tx":
    let acc = mx.getAccount(15)
    let tc = BaseTx(
      txType: Opt.some(TxLegacy),
      gasLimit: 75000
    )

    var ptx = mx.makeTx(tc, acc, 0)
    xp.checkAddTx(ptx)

    let oldPrice = ptx.tx.gasPrice
    ptx.tx = mx.customizeTransaction(acc, ptx.tx,
      CustomTx(gasPriceOrGasFeeCap: Opt.some(oldPrice*2)))
    xp.checkAddTxSupersede(ptx)

    let bundle = xp.checkAssembleBlock(1)
    check bundle.blk.transactions[0].gasPrice == oldPrice*2
    xp.checkImportBlock(bundle, 0)

  test "removeNewBlockTxs after two blocks":
    let tc = BaseTx(
      gasLimit: 75000
    )

    var ptx = mx.makeNextTx(tc)
    xp.checkAddTx(ptx)

    xp.checkImportBlock(1)

    ptx = mx.makeNextTx(tc)
    xp.checkAddTx(ptx)

    xp.checkImportBlock(1, 0)

  test "max transactions per account":
    let acc = mx.getAccount(16)
    let tc = BaseTx(
      txType: Opt.some(TxLegacy),
      gasLimit: 75000
    )

    const MAX_TXS_GENERATED = 100
    for i in 0..MAX_TXS_GENERATED-2:
      let ptx = mx.makeTx(tc, acc, i.AccountNonce)
      xp.checkAddTx(ptx)

    var ptx = mx.makeTx(tc, acc, MAX_TXS_GENERATED-1)
    xp.checkAddTx(ptx)

    let ptxMax = mx.makeTx(tc, acc, MAX_TXS_GENERATED)
    xp.checkAddTx(ptxMax, txErrorSenderMaxTxs)

    # superseding not hit sender max txs
    let oldPrice = ptx.tx.gasPrice
    ptx.tx = mx.customizeTransaction(acc, ptx.tx,
      CustomTx(gasPriceOrGasFeeCap: Opt.some(oldPrice*2)))
    xp.checkAddTxSupersede(ptx)

    var numTxsPacked = 0
    while numTxsPacked < MAX_TXS_GENERATED:
      xp.timestamp = xp.timestamp + 1
      let bundle = xp.assembleBlock().valueOr:
        debugEcho error
        check false
        return

      numTxsPacked += bundle.blk.transactions.len

      (waitFor chain.importBlock(bundle.blk)).isOkOr:
        check false
        debugEcho error
        return

      xp.removeNewBlockTxs(bundle.blk)

    check xp.len == 0

  test "auto remove lower nonces":
    let xp2 = TxPoolRef.new(chain)
    let acc = mx.getAccount(17)
    let tc = BaseTx(
      gasLimit: 75000
    )

    let ptx0 = mx.makeTx(tc, acc, 0)
    xp.checkAddTx(ptx0)
    xp2.checkAddTx(ptx0)

    let ptx1 = mx.makeTx(tc, acc, 1)
    xp.checkAddTx(ptx1)
    xp2.checkAddTx(ptx1)

    let ptx2 = mx.makeTx(tc, acc, 2)
    xp.checkAddTx(ptx2)

    xp2.checkImportBlock(2, 0)

    xp.timestamp = xp2.timestamp + 1
    xp.checkImportBlock(1, 0)

  test "mixed type of transactions":
    let acc = mx.getAccount(18)
    let
      tc1 = BaseTx(
        txType: Opt.some(TxLegacy),
        gasLimit: 75000
      )
      tc2 = BaseTx(
        txType: Opt.some(TxEip1559),
        gasLimit: 75000
      )
      tc3 = BaseTx(
        txType: Opt.some(TxEip4844),
        recipient: Opt.some(recipient),
        gasLimit: 75000
      )

    let ptx0 = mx.makeTx(tc1, acc, 0)
    let ptx1 = mx.makeTx(tc2, acc, 1)
    let ptx2 = mx.makeTx(tc3, acc, 2)

    xp.checkAddTx(ptx0)
    xp.checkAddTx(ptx1)
    xp.checkAddTx(ptx2)
    xp.checkImportBlock(3, 0)

  test "replacement gas too low":
    let acc = mx.getAccount(19)
    let
      tc1 = BaseTx(
        txType: Opt.some(TxLegacy),
        gasLimit: 75000
      )
      tc2 = BaseTx(
        txType: Opt.some(TxEip4844),
        recipient: Opt.some(recipient),
        gasLimit: 75000
      )

    var ptx0 = mx.makeTx(tc1, acc, 0)
    var ptx1 = mx.makeTx(tc2, acc, 1)

    xp.checkAddTx(ptx0)
    xp.checkAddTx(ptx1)

    var oldPrice = ptx0.tx.gasPrice
    ptx0.tx = mx.customizeTransaction(acc, ptx0.tx,
      CustomTx(gasPriceOrGasFeeCap: Opt.some(oldPrice+1)
    ))
    xp.checkAddTx(ptx0, txErrorReplacementGasTooLow)

    let oldGas = ptx1.tx.maxFeePerBlobGas
    let oldTip = ptx1.tx.maxPriorityFeePerGas
    oldPrice = ptx1.tx.maxFeePerGas
    ptx1.tx = mx.customizeTransaction(acc, ptx1.tx,
      CustomTx(blobGas: Opt.some(oldGas+1),
      gasTipCap: Opt.some(oldTip*2),
      gasPriceOrGasFeeCap: Opt.some(oldPrice*2)
    ))
    xp.checkAddTx(ptx1, txErrorReplacementBlobGasTooLow)
    xp.checkImportBlock(2, 0)

  test "Test TxPool with PoS block":
    let
      acc = mx.getAccount(20)
      tc = BaseTx(
        txType: Opt.some(TxLegacy),
        recipient: Opt.some(recipient),
        gasLimit: 75000,
        amount: amount,
      )
      ptx = mx.makeTx(tc, acc, 0)

    xp.checkAddTx(ptx)
    let bundle = xp.checkAssembleBlock(1)
    xp.checkImportBlock(bundle, 0)

    let
      sdb = LedgerRef.init(chain.latestTxFrame)
      val = sdb.getStorage(recipient, slot)
      randao = Bytes32(val.toBytesBE)
      fee = sdb.getBalance(feeRecipient)
      bal = sdb.getBalance(recipient)

    check randao == prevRandao
    check bundle.blk.header.coinbase == feeRecipient
    check not fee.isZero
    check bal >= 1000.u256

  test "Test TxPool with blobhash block":
    let
      acc = mx.getAccount(21)
      tx1 = mx.createPooledTransactionWithBlob(acc, recipient, amount, 0)
      tx2 = mx.createPooledTransactionWithBlob(acc, recipient, amount, 1)

    xp.checkAddTx(tx1)
    xp.checkAddTx(tx2)

    template header(): Header =
      bundle.blk.header

    let
      bundle = xp.checkAssembleBlock(2)
      gasUsed1 = xp.vmState.receipts[0].cumulativeGasUsed
      gasUsed2 = xp.vmState.receipts[1].cumulativeGasUsed - gasUsed1
      totalBlobGasUsed = tx1.tx.getTotalBlobGas + tx2.tx.getTotalBlobGas
      blockValue =
        gasUsed1.u256 * tx1.tx.effectiveGasTip(header.baseFeePerGas).u256 +
        gasUsed2.u256 * tx2.tx.effectiveGasTip(header.baseFeePerGas).u256

    check blockValue == bundle.blockValue
    check totalBlobGasUsed == header.blobGasUsed.get()

    xp.checkImportBlock(bundle, 0)

    let
      sdb = LedgerRef.init(chain.latestTxFrame)
      val = sdb.getStorage(recipient, slot)
      randao = Bytes32(val.toBytesBE)
      bal = sdb.getBalance(feeRecipient)

    check randao == prevRandao
    check header.coinbase == feeRecipient
    check not bal.isZero

  ## see github.com/status-im/nimbus-eth1/issues/1031
  test "TxPool: Synthesising blocks (covers issue #1031)":
    const
      txPerblock = 20
      numBlocks = 10

    let
      lastNumber = chain.latestNumber
      tc = BaseTx(
        gasLimit: 75000,
        recipient: Opt.some(recipient214),
        amount: amount,
      )

    for n in 0 ..< numBlocks:
      for tn in 0 ..< txPerblock:
        let tx = mx.makeNextTx(tc)
        xp.checkAddTx(tx)

      xp.checkImportBlock(txPerblock, 0)

    let syncCurrent = lastNumber + numBlocks
    let
      head = chain.headerByNumber(syncCurrent).expect("block header exists")
      sdb = LedgerRef.init(chain.latestTxFrame)
      expected = u256(txPerblock * numBlocks) * amount
      balance = sdb.getBalance(recipient214)
    check balance == expected
    discard head

  test "Test get parent transactions after persistBlock":
    let
      acc = mx.getAccount(22)
      tx1 = mx.makeTx(acc, recipient, 1.u256, 0)
      tx2 = mx.makeTx(acc, recipient, 2.u256, 1)

    xp.checkAddTx(tx1)
    xp.checkAddTx(tx2)

    xp.checkImportBlock(2, 0)

    let
      tx3 = mx.makeTx(acc, recipient, 3.u256, 2)
      tx4 = mx.makeTx(acc, recipient, 4.u256, 3)
      tx5 = mx.makeTx(acc, recipient, 5.u256, 4)

    xp.checkAddTx(tx3)
    xp.checkAddTx(tx4)
    xp.checkAddTx(tx5)

    xp.checkImportBlock(3, 0)
    let latestHash = chain.latestHash
    check (waitFor env.chain.forkChoice(latestHash, latestHash)).isOk

    let hs = [
      computeRlpHash(tx1),
      computeRlpHash(tx2),
      computeRlpHash(tx3),
      computeRlpHash(tx4),
      computeRlpHash(tx5),
    ]

    let res = chain.blockByNumber(chain.latestHeader.number - 1)
    if res.isErr:
      debugEcho res.error
      check false

    let parent = res.get
    var count = 0
    for txh in chain.txHashInRange(latestHash, parent.header.parentHash):
      check txh in hs
      inc count
    check count == hs.len

  test "EIP-7702 transaction before Prague":
    let
      acc = mx.getAccount(24)
      auth = mx.makeAuth(acc, 0)
      tc = BaseTx(
        txType: Opt.some(TxEip7702),
        gasLimit: 75000,
        recipient: Opt.some(recipient214),
        amount: amount,
        authorizationList: @[auth],
      )
      tx = mx.makeTx(tc, 0)

    xp.checkAddTx(tx, txErrorBasicValidation)

  test "EIP-7702 transaction invalid auth signature":
    let
      env = initEnv(Prague)
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(25)
      auth = mx.makeAuth(acc, 0)
      tc = BaseTx(
        txType: Opt.some(TxEip7702),
        gasLimit: 75000,
        recipient: Opt.some(recipient214),
        amount: amount,
        authorizationList: @[auth],
      )
      ptx = mx.makeTx(tc, 0)

    # invalid auth
    var invauth = auth
    invauth.v = 3.uint64
    let
      ctx = CustomTx(auth: Opt.some(invauth))
      tx  = mx.customizeTransaction(acc, ptx.tx, ctx)

    xp.checkAddTx(tx)
    # invalid auth, but the tx itself still valid
    xp.checkImportBlock(1, 0)

  test "Blobschedule":
    let
      cc = env.conf.networkParams.config
      acc = mx.getAccount(26)
      tc = BlobTx(
        txType: Opt.some(TxEip4844),
        gasLimit: 75000,
        recipient: Opt.some(acc.address),
        blobID: 0.BlobID,
        blobCount: 1
      )
      tx1 = mx.makeTx(tc, acc, 0)
      tx2 = mx.makeTx(tc, acc, 1)
      tx3 = mx.makeTx(tc, acc, 2)
      tx4 = mx.makeTx(tc, acc, 3)

    xp.checkAddTx(tx1)
    xp.checkAddTx(tx2)
    xp.checkAddTx(tx3)
    xp.checkAddTx(tx4)

    # override current blobSchedule
    let bs = cc.blobSchedule[Cancun]
    cc.blobSchedule[Cancun] = Opt.some(
      BlobSchedule(target: 2, max: 3, baseFeeUpdateFraction: 3338477)
    )

    # allow 3 blobs
    xp.checkImportBlock(3, 1)

    # consume the rest of blobs
    xp.checkImportBlock(1, 0)

    # restore blobSchedule
    cc.blobSchedule[Cancun] = bs

  test "non blob tx size limit":
    proc dataTx(nonce: AccountNonce, env: TestEnv, btx: BaseTx): (PooledTransaction, PooledTransaction) =
      const largeDataLength = TX_MAX_SIZE - 200 # enough to have a 5 bytes RLP encoding of the data length number
      var tc = btx
      tc.payload = newSeq[byte](largeDataLength)

      let
        mx = env.sender
        acc = mx.getAccount(27)
        ptx = mx.makeTx(tc, 0)
        txSize = getEncodedLength(ptx.tx)
        maxTxLengthWithoutData = txSize - largeDataLength
        maxTxDataLength = TX_MAX_SIZE - maxTxLengthWithoutData

      tc.payload = newSeq[byte](maxTxDataLength)
      let ptx1 = mx.makeTx(tc, acc, nonce)
      tc.payload = newSeq[byte](maxTxDataLength + 1)
      let ptx2 = mx.makeTx(tc, acc, nonce)
      (ptx1, ptx2)

    let
      env = initEnv(Prague)
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(27)

    let
      auth = mx.makeAuth(acc, 0)

      (tx1ok, tx1bad) = dataTx(0, env, BaseTx(
        txType: Opt.some(TxEip7702),
        gasLimit: 3_000_000,
        recipient: Opt.some(recipient214),
        amount: amount,
        authorizationList: @[auth],
      ))

      (tx2ok, tx2bad) = dataTx(1, env, BaseTx(
        txType: Opt.some(TxLegacy),
        recipient: Opt.some(recipient214),
        gasLimit: 3_000_000
      ))

      (tx3ok, tx3bad) = dataTx(2, env, BaseTx(
        txType: Opt.some(TxEip1559),
        recipient: Opt.some(recipient214),
        gasLimit: 3_000_000
      ))

      (tx4init, tx4bad) = dataTx(3, env, BaseTx(
        txType: Opt.some(TxLegacy),
        gasLimit: 3_000_000
      ))

    xp.checkAddTx(tx1ok)
    xp.checkAddTx(tx2ok)
    xp.checkAddTx(tx3ok)

    xp.checkAddTx(tx1bad, txErrorOversized)
    xp.checkAddTx(tx2bad, txErrorOversized)
    xp.checkAddTx(tx3bad, txErrorOversized)

    # exceeds max init code size
    xp.checkAddTx(tx4init, txErrorBasicValidation)
    xp.checkAddTx(tx4bad, txErrorOversized)

    xp.checkImportBlock(1, 2)
    xp.checkImportBlock(1, 1)
    xp.checkImportBlock(1, 0)

  test "EIP-7702 transaction invalid zero auth":
    let
      env = initEnv(Prague)
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(29)
      tc = BaseTx(
        txType: Opt.some(TxEip7702),
        gasLimit: 75000,
        recipient: Opt.some(recipient214),
        amount: amount,
      )
      tx = mx.makeTx(tc, acc, 0)

    xp.checkAddTx(tx, txErrorBasicValidation)

  test "EIP-7594 BlobsBundle on Prague":
    let
      env = initEnv(Prague)
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(0)
      tx = mx.createPooledTransactionWithBlob7594(acc, recipient, amount, 0)

    check tx.blobsBundle.wrapperVersion == WrapperVersionEIP7594
    xp.checkAddTx(tx)
    xp.checkImportBlock(0, 1)

  test "EIP-4844 BlobsBundle on Osaka":
    let
      env = initEnv(Osaka)
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(0)
      tx = mx.createPooledTransactionWithBlob(acc, recipient, amount, 0)

    check tx.blobsBundle.wrapperVersion == WrapperVersionEIP4844
    xp.checkAddTx(tx, txErrorInvalidBlob)

  test "EIP-7594 BlobsBundle on Osaka":
    let
      env = initEnv(Osaka)
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(0)
      tx = mx.createPooledTransactionWithBlob7594(acc, recipient, amount, 0)

    check tx.blobsBundle.wrapperVersion == WrapperVersionEIP7594
    xp.checkAddTx(tx)
    xp.checkImportBlock(1, 0)

  test "EIP-7594 BlobsBundle transition from Prague to Osaka":
    let
      conf = initConf(Prague)
      cc = conf.networkParams.config
      timestamp = EthTime.now()

    # set osaka transition time
    cc.osakaTime = Opt.some(timestamp + 2)

    let
      env = initEnv(conf)
      xp = env.xp
      mx = env.sender
      acc = mx.getAccount(0)
      acc1 = mx.getAccount(1)
      tx0 = mx.createPooledTransactionWithBlob(acc, recipient, amount, 0)
      tx1 = mx.createPooledTransactionWithBlob(acc, recipient, amount, 1)

    let bs = cc.blobSchedule[Prague]
    cc.blobSchedule[Prague] = Opt.some(
      BlobSchedule(target: 1, max: 1, baseFeeUpdateFraction: 5_007_716'u64)
    )

    xp.timestamp = timestamp
    xp.checkAddTx(tx0)
    xp.checkAddTx(tx1)

    # allow 1 blob tx, remaining 1
    xp.checkImportBlock(1, 1)

    let tx2 = mx.createPooledTransactionWithBlob7594(acc1, recipient, amount, 0)
    xp.checkAddTx(tx2)

    # still 2 txs in pool
    check xp.len == 2

    # only allow 1 blob tx, the other one removed automatically
    xp.checkImportBlock(1, 0)

    check xp.com.isOsakaOrLater(xp.timestamp)

    # restore blobSchedule
    cc.blobSchedule[Prague] = bs
