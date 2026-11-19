## The codec closure (spec §13.4): rust/haus-build-tests/shop.schema.haus
## uses schema packages, and the codec for @haus-test/money@1#Money applies
## inside their types too. Shop*.roc are generated (../examples/gen.sh);
## run with `roc test main.roc`.
package
	[Cents, ClosureTest, Shop, ShopHausTestLedger, ShopHausTestOrders]
	{
		haus: "../package/main.roc",
		ledger: "ledger/main.roc",
		money: "money/main.roc",
		orders: "orders/main.roc",
	}
