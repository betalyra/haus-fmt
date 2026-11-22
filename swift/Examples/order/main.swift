// The same order, decoded with the schema's own types and with the app's
// codecs. The same steps as go/examples/order and rust/examples/order, on
// the same files. Run: swift run order (from swift/).
import Foundation
import Haus

/// The root of the repository.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// `UserId("usr_ada")`: a tag with one argument is a struct of one field.
struct UserId: Codable {
    let id: String
}

/// One of Pending, Shipped and Cancelled: an enum, a case per tag.
enum Status: Codable {
    case pending
    case shipped(tracking: String)
    case cancelled
}

/// The schema's Root with its own types: Money is Money(Decimal, Currency).
struct PlainOrder: Codable {
    let id: Int
    let customer: UserId
    let placed: String
    let total: Money
    let deliverTo: LatLng
    let status: Status
}

/// The schema's Root with the codecs' types.
struct Order: Codable {
    let id: Int
    let customer: UserId
    let placed: Day
    let total: Amount
    let deliverTo: LngLat
    let status: Status
}

do {
    // The packages the schema imports, @haus-fmt/money and @haus-fmt/geo,
    // given in a folder (a Swift package can ship them as resources:
    // PackageLocator.explicit(in: Bundle.module, folders: […])).
    let packages = try PackageLocator.explicit(folders: [root.appendingPathComponent("extensions").path])
    let schema = try HausSchema(
        contentsOf: root.appendingPathComponent("examples/order.schema.haus").path,
        options: HausSchema.Options(packages: packages))
    let rootType = try schema.type("Root")
    let order = try String(contentsOf: root.appendingPathComponent("examples/order.haus"), encoding: .utf8)

    // Without codecs: Money is Money(Decimal, Currency), the Decimal as its exact text.
    let plain = try rootType.decode(PlainOrder.self, fromText: order)
    if case .money(let amount, let currency) = plain.total {
        print("plain:  \(plain.customer.id) pays \(amount) \(currency)")
    }

    // With codecs: the fields have the codecs' types.
    let typed = try rootType.decode(Order.self, fromText: order)
    print(
        "typed:  \(typed.customer.id) pays \(typed.total.cents) cents, deliver to [lng, lat] [\(typed.deliverTo.lng), \(typed.deliverTo.lat)]"
    )
    print("placed: \(typed.placed.hausBase), a \(typed.placed.weekday)")

    // Variants are enums: switch on them.
    switch typed.status {
    case .shipped(let tracking): print("status: shipped, tracking \(tracking)")
    case .pending, .cancelled: print("status: not on its way")
    }

    // Encoding with the same codecs gives back the same haus text.
    print(try rootType.stringify(typed, FormatOptions(layout: .compact)), terminator: "")

    // Codecs add rules on top of the schema's: Eur is a valid tag, but not ISO-shaped.
    let eur = order.replacingOccurrences(of: "EUR", with: "Eur")
    if (try? rootType.decode(PlainOrder.self, fromText: eur)) != nil {
        print("Eur without codecs: accepted")
    }
    do {
        _ = try rootType.decode(Order.self, fromText: eur)
    } catch {
        print("Eur with codecs: \(error)")
    }
    do {
        _ = try rootType.decode(Order.self, fromText: order.replacingOccurrences(of: "44.40", with: "44.405"))
    } catch {
        print("44.405 with codecs: \(error)")
    }
} catch {
    print(error)
    exit(1)
}
