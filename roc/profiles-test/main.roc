## The official profiles' codecs (spec §13.3, §13.4): money.Iso,
## money.IsoCurrency, geo.Wgs84 and geo.Wgs84BBox. ProfilesTest checks every
## test vector of extensions/*/profiles/*.vectors.haus, the rules' edge cases,
## and the codecs inside the types of a package that uses the official ones
## (rust/haus-build-tests/travel.schema.haus). Travel*.roc and travel/ are
## generated (../examples/gen.sh); run with `roc test main.roc`.
package
	[ProfilesTest, Travel, TravelHausTestTravel]
	{
		geo: "../../extensions/geo/roc/main.roc",
		haus: "../package/main.roc",
		money: "../../extensions/money/roc/main.roc",
		travel: "travel/main.roc",
	}
