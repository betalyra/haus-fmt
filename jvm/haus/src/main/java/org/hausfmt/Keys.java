package org.hausfmt;

import java.security.SecureRandom;

/**
 * The keys of a large record, by their place in its fields: finds repeated keys while a record
 * is read or built, and the field of a key afterwards, in linear time whatever the keys (spec
 * §7, §9.8).
 *
 * <p>Records with fewer than {@link #FEW} keys don't need one: their keys are compared in order.
 * Larger ones use this open-addressing table with linear probing. It starts with {@link
 * String#hashCode()}, which a string keeps once computed (and which the lookups of a decoder then
 * reuse), and no key may sit more than {@link #LONGEST_PROBE} slots after its own. Keys made to
 * collide break that, and the table is then rebuilt, once, with a hash an attacker can't
 * predict: a polynomial over the key's UTF-16 units modulo the prime {@link #PRIME}, at a point
 * chosen at random per process. Two different keys of at most L units collide under it with
 * probability at most L/{@link #PRIME} (a polynomial of degree L has at most L roots), so crafted
 * keys can't make the table quadratic. Either way a key is found, or found missing, within the
 * longest probe a key of the table took.
 */
final class Keys {
  /** Records with fewer keys than this compare a new key with the ones before it. */
  static final int FEW = 16;

  /** The most slots a key may sit after its own while the table uses String.hashCode. */
  private static final int LONGEST_PROBE = 24;

  /** 2^31 − 1, a Mersenne prime: products of two residues fit a long. */
  private static final long PRIME = (1L << 31) - 1;
  /** The point the polynomial is evaluated at, secret and different in every process. */
  private static final long POINT = 2 + Math.floorMod(new SecureRandom().nextLong(), PRIME - 2);

  /** {@link #freeSlot}: the key is in the table. */
  private static final int PRESENT = -1;
  /** {@link #freeSlot}: the key's slot would be too far from its own. */
  private static final int TOO_FAR = -2;

  /** The keys, by slot; null for an empty slot. */
  private String[] slots;
  /** The place of each slot's key in the record's fields. */
  private int[] places;
  private int size;
  /** Whether the table hashes with the polynomial: String.hashCode put some key too far. */
  private boolean secure;
  /** The most slots any key sits after its own: a key not found within them isn't there. */
  private int longest;

  Keys(int expected) {
    int capacity = Integer.highestOneBit(Math.max(4 * expected, 2 * FEW) - 1) << 1;
    slots = new String[capacity];
    places = new int[capacity];
  }

  /** The keys of a record's fields, or null if a record of this many fields needs none. */
  static Keys of(String[] keys, int n) {
    if (n < FEW) {
      return null;
    }
    Keys index = new Keys(n);
    for (int i = 0; i < n; i++) {
      index.add(keys[i], i);
    }
    return index;
  }

  /** The place of {@code key} among {@code keys[from..to)}, searched in order (for small records), or −1. */
  static int find(String[] keys, int from, int to, String key) {
    for (int i = from; i < to; i++) {
      if (keys[i].equals(key)) {
        return i - from;
      }
    }
    return -1;
  }

  /** Adds the key of the field at {@code place}: false, and nothing added, if it is there already. */
  boolean add(String key, int place) {
    if (2 * (size + 1) > slots.length) {
      rebuild(2 * slots.length);
    }
    while (true) {
      int slot = freeSlot(key);
      if (slot == PRESENT) {
        return false;
      }
      if (slot != TOO_FAR) {
        put(slot, key, place);
        return true;
      }
      secure = true;
      rebuild(slots.length);
    }
  }

  /** The place of the field with the key, or −1. */
  int placeOf(String key) {
    int mask = slots.length - 1;
    int i = hash(key) & mask;
    for (int probe = 0; probe <= longest; probe++, i = i + 1 & mask) {
      String k = slots[i];
      if (k == null) {
        return -1;
      }
      if (k.equals(key)) {
        return places[i];
      }
    }
    return -1;
  }

  /**
   * The slot a key that isn't in the table goes to: the first free one from its own. {@link
   * #PRESENT} if the key is there (a key sits before the first free slot after its own), {@link
   * #TOO_FAR} if that slot is too far while the table uses String.hashCode.
   */
  private int freeSlot(String key) {
    int mask = slots.length - 1;
    int i = hash(key) & mask;
    for (int probe = 0; ; probe++, i = i + 1 & mask) {
      String k = slots[i];
      if (k == null) {
        return probe <= LONGEST_PROBE || secure ? i : TOO_FAR;
      }
      if (k.equals(key)) {
        return PRESENT;
      }
      if (probe >= LONGEST_PROBE && !secure) {
        return TOO_FAR; // no key sits farther: the key isn't there, and its slot would be too far
      }
    }
  }

  private void put(int slot, String key, int place) {
    int mask = slots.length - 1;
    slots[slot] = key;
    places[slot] = place;
    size++;
    longest = Math.max(longest, slot - (hash(key) & mask) & mask);
  }

  /**
   * Puts the keys into a table of {@code capacity} slots, hashing with the polynomial once
   * String.hashCode puts one too far.
   */
  private void rebuild(int capacity) {
    String[] oldSlots = slots;
    int[] oldPlaces = places;
    while (true) {
      slots = new String[capacity];
      places = new int[capacity];
      size = 0;
      longest = 0;
      int i = 0;
      for (; i < oldSlots.length; i++) {
        if (oldSlots[i] != null) {
          int slot = freeSlot(oldSlots[i]);
          if (slot == TOO_FAR) {
            break;
          }
          put(slot, oldSlots[i], oldPlaces[i]);
        }
      }
      if (i == oldSlots.length) {
        return;
      }
      secure = true;
    }
  }

  /** The slot hash: String.hashCode with its high bits folded in, or the polynomial. */
  private int hash(String key) {
    if (!secure) {
      int h = key.hashCode();
      return h ^ h >>> 16;
    }
    return polynomial(key);
  }

  /**
   * The key's polynomial at {@link #POINT}, modulo {@link #PRIME}: 31 bits, spread evenly. The
   * remainder is taken as for any Mersenne prime, without a division: {@code x = hi·2^31 + lo} is
   * {@code hi + lo} modulo 2^31 − 1.
   */
  private static int polynomial(String key) {
    long h = key.length();
    for (int i = 0; i < key.length(); i++) {
      // h < PRIME and POINT < PRIME, so x < 2^62.
      long x = h * POINT + key.charAt(i);
      h = (x & PRIME) + (x >>> 31); // < 2^32, and the same residue
      h = (h & PRIME) + (h >>> 31); // ≤ PRIME
      if (h >= PRIME) {
        h -= PRIME;
      }
    }
    return (int) h;
  }
}
