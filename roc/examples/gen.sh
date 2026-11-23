#!/bin/sh
# Regenerate the Roc modules of the examples and the schema packages from
# their schemas. haus-gen is part of haus-fmt-build, so this needs Rust (cargo).
set -e
cd "$(dirname "$0")"
gen() { cargo run -q --manifest-path ../../rust/Cargo.toml -p haus-fmt-build --bin haus-gen -- "$@"; }

# The official schema packages, as Roc packages.
gen roc-package ../../extensions/money --out ../../extensions/money/roc/HausFmtMoney.roc
gen roc-package ../../extensions/geo --out ../../extensions/geo/roc/HausFmtGeo.roc
gen roc-package ../../extensions/uuid --out ../../extensions/uuid/roc/HausFmtUuid.roc

# The examples, from the shared files in ../../examples.
gen roc ../../examples/thread.schema.haus --module Thread --out quickstart/Thread.roc
gen roc ../../examples/logs.schema.haus --module Logs --out logs/Logs.roc
gen roc ../../examples/order.schema.haus --module Order --out order/Order.roc \
  --package ../../extensions/money=money --package ../../extensions/geo=geo
gen roc ../../examples/order.schema.haus --module Typed --out order/Typed.roc \
  --package ../../extensions/money=money --package ../../extensions/geo=geo \
  --codec "@haus-fmt/money@1#Money=Cents" --codec "@haus-fmt/geo@1#LatLng=GeoJson" --codec "std/time#Date=CivilDate"

# The codec closure (spec §13.4): the packages of rust/haus-build-tests and
# its shop.schema.haus, with a codec for Money that applies inside the
# packages' types (../closure-test, `roc test main.roc` there).
packages=../../rust/haus-build-tests/packages
closure=../closure-test
gen roc-package $packages/money --json --out $closure/money/HausTestMoney.roc
gen roc-package $packages/ledger --json --package $packages/money=money --out $closure/ledger/HausTestLedger.roc
gen roc-package $packages/orders --json --package $packages/ledger=ledger --package $packages/money=money \
  --out $closure/orders/HausTestOrders.roc
gen roc ../../rust/haus-build-tests/shop.schema.haus --module Shop --id shop --json --out $closure/Shop.roc \
  --package $packages/orders=orders --package $packages/ledger=ledger --package $packages/money=money \
  --codec "@haus-test/money@1#Money=Cents"

for f in $closure/money/HausTestMoney.roc $closure/ledger/HausTestLedger.roc $closure/orders/HausTestOrders.roc \
  $closure/Shop.roc $closure/ShopHausTestOrders.roc $closure/ShopHausTestLedger.roc; do
  roc fmt "$f" >/dev/null
done
# The official profiles' codecs (the Roc modules of extensions/*/roc), inside
# the types of a package that uses the official packages:
# rust/haus-build-tests/travel.schema.haus (../profiles-test, `roc test main.roc` there).
profiles=../profiles-test
official="--package ../../extensions/money=money --package ../../extensions/geo=geo"
gen roc-package $packages/travel $official --out $profiles/travel/HausTestTravel.roc
gen roc ../../rust/haus-build-tests/travel.schema.haus --module Travel --id travel --out $profiles/Travel.roc \
  --package $packages/travel=travel $official \
  --codec "@haus-fmt/money@1#Money=money.Iso" --codec "@haus-fmt/money@1#Currency=money.IsoCurrency" \
  --codec "@haus-fmt/geo@1#LatLng=geo.Wgs84" --codec "@haus-fmt/geo@1#BBox=geo.Wgs84BBox"
for f in $profiles/travel/HausTestTravel.roc $profiles/Travel.roc $profiles/TravelHausTestTravel.roc; do
  roc fmt "$f" >/dev/null
done

for f in ../../extensions/money/roc/HausFmtMoney.roc ../../extensions/geo/roc/HausFmtGeo.roc ../../extensions/uuid/roc/HausFmtUuid.roc quickstart/Thread.roc logs/Logs.roc order/Order.roc order/Typed.roc; do
  roc fmt "$f" >/dev/null
done
