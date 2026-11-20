package org.hausfmt;

import java.security.SecureRandom;

/**
 * The keys of a large record, by their place in its fields: finds repeated keys while a record
 * is read or built, and the field of a key afterwards, in linear time whatever the keys (spec
 * §7, §9.8).
 *
 * <p>Records with fewer than {@link #FEW} keys don't need one: their keys are compared in order.
 * Larger ones use this open-addressing table, whose hash an attacker can't predict: a polynomial
 * over the key's UTF-16 units modulo the prime {@link #PRIME}, at a point chosen at random per
 * process. Two different keys of at most L units collide with probability at most L/{@link #PRIME}
 * (a polynomial of degree L has at most L roots), so crafted keys can't make the table quadratic,
 * as they can with {@link String#hashCode()}.
 */
final class Keys {
  /** Records with fewer keys than this compare a new key with the ones before it. */
  static final int FEW = 16;

  /** 2^31 − 1, a Mersenne prime: products of two residues fit a long. */
  private static final long PRIME = (1L << 31) - 1;
  /** The point the polynomial is evaluated at, secret and different in every process. */
  private static final long POINT = 2 + Math.floorMod(new SecureRandom().nextLong(), PRIME - 2);

  /** The keys, by slot; null for an empty slot. */
  private String[] slots;
  /** The place of each slot's key in the record's fields. */
  private int[] places;
  private int size;

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
      grow();
    }
    int mask = slots.length - 1;
    for (int i = hash(key) & mask; ; i = i + 1 & mask) {
      String k = slots[i];
      if (k == null) {
        slots[i] = key;
        places[i] = place;
        size++;
        return true;
      }
      if (k.equals(key)) {
        return false;
      }
    }
  }

  /** The place of the field with the key, or −1. */
  int placeOf(String key) {
    int mask = slots.length - 1;
    for (int i = hash(key) & mask; ; i = i + 1 & mask) {
      String k = slots[i];
      if (k == null) {
        return -1;
      }
      if (k.equals(key)) {
        return places[i];
      }
    }
  }

  private void grow() {
    String[] oldSlots = slots;
    int[] oldPlaces = places;
    slots = new String[2 * oldSlots.length];
    places = new int[2 * oldSlots.length];
    size = 0;
    for (int i = 0; i < oldSlots.length; i++) {
      if (oldSlots[i] != null) {
        add(oldSlots[i], oldPlaces[i]);
      }
    }
  }

  /** The key's polynomial at {@link #POINT}, modulo {@link #PRIME}: 31 bits, spread evenly. */
  private static int hash(String key) {
    long h = key.length();
    for (int i = 0; i < key.length(); i++) {
      h = (h * POINT + key.charAt(i)) % PRIME;
    }
    return (int) h;
  }
}
