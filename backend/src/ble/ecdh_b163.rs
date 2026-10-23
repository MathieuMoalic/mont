//! ECDH on NIST `B-163`, ported byte-exactly from Gadgetbridge's
//! `ECDH_B163.java` (itself a port of tiny-ECDH).
//!
//! This is the key exchange behind `ZeppOS` session encryption (chunked
//! endpoint `0x0082`).
//!
//! Keys are little-endian word arrays: a private key is 24 bytes, a public
//! key is `x ‖ y` (24 bytes each). All arithmetic is in GF(2^163); the words
//! hold 6 × u32 little-endian, mirroring the Java `int[]` bit-vectors.

const CURVE_DEGREE: usize = 163;
const ECC_PRV_KEY_SIZE: usize = 24;
const ECC_PUB_KEY_SIZE: usize = 2 * ECC_PRV_KEY_SIZE;
/// Margin for overhead needed in intermediate calculations.
const BITVEC_MARGIN: usize = 3;
const BITVEC_NBITS: usize = CURVE_DEGREE + BITVEC_MARGIN;
const BITVEC_NWORDS: usize = BITVEC_NBITS.div_ceil(32);
const BITVEC_NBYTES: usize = 4 * BITVEC_NWORDS;

type Bitvec = [u32; BITVEC_NWORDS];

// NIST B-163 curve parameters (word order matches the Java arrays).
const POLYNOMIAL: Bitvec = [0x0000_00c9, 0, 0, 0, 0, 0x0000_0008];
const COEFF_B: Bitvec = [
    0x4a32_05fd,
    0x512f_7874,
    0x1481_eb10,
    0xb8c9_53ca,
    0x0a60_1907,
    0x0000_0002,
];
const BASE_X: Bitvec = [
    0xe834_3e36,
    0xd499_4637,
    0xa099_1168,
    0x86a2_d57e,
    0xf0eb_a162,
    0x0000_0003,
];
const BASE_Y: Bitvec = [
    0x7973_24f1,
    0xb11c_5c0c,
    0xa2cd_d545,
    0x71a0_094f,
    0xd51f_bc6c,
    0x0000_0000,
];
const BASE_ORDER: Bitvec = [0xa423_4c33, 0x77e7_0c12, 0x0002_92fe, 0, 0, 0x0000_0004];

const fn bitvec_get_bit(x: &Bitvec, idx: usize) -> u32 {
    (x[idx / 32] >> (idx % 32)) & 1
}

const fn bitvec_clr_bit(x: &mut Bitvec, idx: usize) {
    x[idx / 32] &= !(1 << (idx % 32));
}

fn bitvec_equal(x: &Bitvec, y: &Bitvec) -> bool {
    x == y
}

const fn bitvec_set_zero(x: &mut Bitvec) {
    *x = [0; BITVEC_NWORDS];
}

fn bitvec_is_zero(x: &Bitvec) -> bool {
    x.iter().all(|&w| w == 0)
}

/// Number of the highest one-bit + 1 (0 for zero).
fn bitvec_degree(x: &Bitvec) -> usize {
    for word in (0..BITVEC_NWORDS).rev() {
        if x[word] != 0 {
            return word * 32 + (31 - x[word].leading_zeros() as usize) + 1;
        }
    }
    0
}

/// `x := y << nbits`. `x` and `y` must be distinct.
fn bitvec_lshift(x: &mut Bitvec, y: &Bitvec, nbits: u32) {
    let nwords = (nbits / 32) as usize;
    x[..nwords].fill(0);
    let mut i = nwords;
    let mut j = 0usize;
    while i < BITVEC_NWORDS {
        x[i] = y[j];
        i += 1;
        j += 1;
    }
    let rest = nbits % 32;
    if rest != 0 {
        for w in (1..BITVEC_NWORDS).rev() {
            x[w] = (x[w] << rest) | (x[w - 1] >> (32 - rest));
        }
        x[0] <<= rest;
    }
}

/// In-place `x <<= 1` (the only aliased shift the algorithms need).
fn bitvec_lshift1(x: &mut Bitvec) {
    for w in (1..BITVEC_NWORDS).rev() {
        x[w] = (x[w] << 1) | (x[w - 1] >> 31);
    }
    x[0] <<= 1;
}

const fn gf2field_set_one(x: &mut Bitvec) {
    *x = [0; BITVEC_NWORDS];
    x[0] = 1;
}

fn gf2field_is_one(x: &Bitvec) -> bool {
    *x == [1, 0, 0, 0, 0, 0]
}

/// `z := x + y` in GF(2^m) — XOR.
fn gf2field_add(z: &mut Bitvec, x: &Bitvec, y: &Bitvec) {
    for w in 0..BITVEC_NWORDS {
        z[w] = x[w] ^ y[w];
    }
}

/// Field multiplication `z := x * y` modulo the reduction polynomial.
/// `z` must not alias `y` (call sites pass copies).
fn gf2field_mul(z: &mut Bitvec, x: &Bitvec, y: &Bitvec) {
    let mut tmp = *x;
    if bitvec_get_bit(y, 0) != 0 {
        *z = *x;
    } else {
        *z = [0; BITVEC_NWORDS];
    }
    for i in 1..CURVE_DEGREE {
        bitvec_lshift1(&mut tmp);
        if bitvec_get_bit(&tmp, CURVE_DEGREE) != 0 {
            for w in 0..BITVEC_NWORDS {
                tmp[w] ^= POLYNOMIAL[w];
            }
        }
        if bitvec_get_bit(y, i) != 0 {
            for w in 0..BITVEC_NWORDS {
                z[w] ^= tmp[w];
            }
        }
    }
}

/// Field inversion `z := 1/x` (extended binary GCD).
/// The single-letter names mirror the tiny-ECDH reference this ports.
#[allow(clippy::many_single_char_names)]
fn gf2field_inv(z: &mut Bitvec, x: &Bitvec) {
    let mut u = *x;
    let mut v = POLYNOMIAL;
    let mut g: Bitvec = [0; BITVEC_NWORDS];
    gf2field_set_one(z);

    while !gf2field_is_one(&u) {
        let (du, dv) = (bitvec_degree(&u), bitvec_degree(&v));
        let (swap_needed, shift) = if du >= dv {
            (false, du - dv)
        } else {
            (true, dv - du)
        };
        if swap_needed {
            std::mem::swap(&mut u, &mut v);
            std::mem::swap(&mut g, z);
        }
        let shift = u32::try_from(shift).unwrap_or(0);
        let mut h: Bitvec = [0; BITVEC_NWORDS];
        bitvec_lshift(&mut h, &v, shift);
        let u_old = u;
        gf2field_add(&mut u, &u_old, &h);
        bitvec_lshift(&mut h, &g, shift);
        let z_old = *z;
        gf2field_add(z, &z_old, &h);
    }
}

const fn gf2point_copy(x1: &mut Bitvec, y1: &mut Bitvec, x2: &Bitvec, y2: &Bitvec) {
    *x1 = *x2;
    *y1 = *y2;
}

const fn gf2point_set_zero(x: &mut Bitvec, y: &mut Bitvec) {
    bitvec_set_zero(x);
    bitvec_set_zero(y);
}

fn gf2point_is_zero(x: &Bitvec, y: &Bitvec) -> bool {
    bitvec_is_zero(x) && bitvec_is_zero(y)
}

const fn gf2field_inc(x: &mut Bitvec) {
    x[0] ^= 1;
}

/// Double the point `(x, y)`:
/// `l = y/x + x; y = x²; x = l²; l += 1; x += l; y += l·x`.
fn gf2point_double(x: &mut Bitvec, y: &mut Bitvec) {
    if bitvec_is_zero(x) {
        bitvec_set_zero(y);
        return;
    }
    let mut l: Bitvec = [0; BITVEC_NWORDS];
    gf2field_inv(&mut l, x);
    let l_old = l;
    gf2field_mul(&mut l, &l_old, y);
    let l_old = l;
    gf2field_add(&mut l, &l_old, x);
    let x_old = *x;
    gf2field_mul(y, &x_old, &x_old);
    let l_sq = {
        let mut t: Bitvec = [0; BITVEC_NWORDS];
        gf2field_mul(&mut t, &l, &l);
        t
    };
    *x = l_sq;
    gf2field_inc(&mut l);
    let x_old = *x;
    gf2field_add(x, &x_old, &l);
    let l_old = l;
    let mut l_times_x: Bitvec = [0; BITVEC_NWORDS];
    gf2field_mul(&mut l_times_x, &l_old, x);
    let y_old = *y;
    gf2field_add(y, &y_old, &l_times_x);
}

/// `(x1, y1) := (x1, y1) + (x2, y2)`.
fn gf2point_add(x1: &mut Bitvec, y1: &mut Bitvec, x2: &Bitvec, y2: &Bitvec) {
    if gf2point_is_zero(x2, y2) {
        return;
    }
    if gf2point_is_zero(x1, y1) {
        gf2point_copy(x1, y1, x2, y2);
        return;
    }
    if bitvec_equal(x1, x2) {
        if bitvec_equal(y1, y2) {
            gf2point_double(x1, y1);
        } else {
            gf2point_set_zero(x1, y1);
        }
        return;
    }
    let mut a: Bitvec = [0; BITVEC_NWORDS];
    let mut b: Bitvec = [0; BITVEC_NWORDS];
    let mut c: Bitvec = [0; BITVEC_NWORDS];
    let mut d: Bitvec = [0; BITVEC_NWORDS];

    let (y1_old, x1_old) = (*y1, *x1);
    gf2field_add(&mut a, &y1_old, y2);
    gf2field_add(&mut b, &x1_old, x2);
    gf2field_inv(&mut c, &b);
    let c_old = c;
    gf2field_mul(&mut c, &c_old, &a);
    let c_old = c;
    gf2field_mul(&mut d, &c_old, &c);
    let d_old = d;
    gf2field_add(&mut d, &d_old, &c);
    let d_old = d;
    gf2field_add(&mut d, &d_old, &b);
    gf2field_inc(&mut d);
    let x1_old = *x1;
    gf2field_add(x1, &x1_old, &d);
    let x1_old = *x1;
    gf2field_mul(&mut a, &x1_old, &c);
    let a_old = a;
    gf2field_add(&mut a, &a_old, &d);
    let y1_old = *y1;
    gf2field_add(y1, &y1_old, &a);
    *x1 = d;
}

/// Point multiplication via double-and-add; `(x, y) := exp · (x, y)`.
fn gf2point_mul(x: &mut Bitvec, y: &mut Bitvec, exp: &Bitvec) {
    let mut acc_x: Bitvec = [0; BITVEC_NWORDS];
    let mut acc_y: Bitvec = [0; BITVEC_NWORDS];

    let nbits = bitvec_degree(exp);
    for i in (0..nbits).rev() {
        gf2point_double(&mut acc_x, &mut acc_y);
        if bitvec_get_bit(exp, i) != 0 {
            gf2point_add(&mut acc_x, &mut acc_y, x, y);
        }
    }
    gf2point_copy(x, y, &acc_x, &acc_y);
}

/// Check `y² + x·y = x³ + x² + b` (curve coefficient a = 1).
#[must_use]
pub fn gf2point_on_curve(x: &Bitvec, y: &Bitvec) -> bool {
    if gf2point_is_zero(x, y) {
        return false;
    }
    let mut a: Bitvec = [0; BITVEC_NWORDS];
    let mut b: Bitvec = [0; BITVEC_NWORDS];
    gf2field_mul(&mut a, x, x);
    let a_old = a;
    gf2field_mul(&mut b, &a_old, x);
    let a_old = a;
    gf2field_add(&mut a, &a_old, &b);
    let a_old = a;
    gf2field_add(&mut a, &a_old, &COEFF_B);
    gf2field_mul(&mut b, y, y);
    let a_old = a;
    gf2field_add(&mut a, &a_old, &b);
    gf2field_mul(&mut b, x, y);
    bitvec_equal(&a, &b)
}

fn bytes_to_bitvec(bytes: &[u8]) -> Bitvec {
    let mut out = [0u32; BITVEC_NWORDS];
    for (w, word) in out.iter_mut().enumerate() {
        let b = &bytes[w * 4..w * 4 + 4];
        *word = u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    }
    out
}

fn bitvec_to_bytes(v: &Bitvec) -> [u8; BITVEC_NBYTES] {
    let mut out = [0u8; BITVEC_NBYTES];
    for (w, word) in v.iter().enumerate() {
        out[w * 4..w * 4 + 4].copy_from_slice(&word.to_le_bytes());
    }
    out
}

/// Public key for a supplied random private key (24 bytes); the private
/// bytes are not modified.
///
/// Returns `None` when the random data is too small (fewer than
/// `CURVE_DEGREE / 2` significant bits) — retry with new randomness.
#[must_use]
pub fn generate_public(private: &[u8; ECC_PRV_KEY_SIZE]) -> Option<[u8; ECC_PUB_KEY_SIZE]> {
    let mut private_int = bytes_to_bitvec(private);
    let mut pub_x = BASE_X;
    let mut pub_y = BASE_Y;

    if bitvec_degree(&private_int) < CURVE_DEGREE / 2 {
        return None;
    }
    // Gadgetbridge clears from `degree(base_order) - 1` (not `degree`) — the
    // scalar is reduced below 2^162, one bit tighter than `< order`. Kept
    // identical for watch compatibility.
    let nbits = bitvec_degree(&BASE_ORDER);
    for bit in (nbits - 1)..BITVEC_NWORDS * 32 {
        bitvec_clr_bit(&mut private_int, bit);
    }
    gf2point_mul(&mut pub_x, &mut pub_y, &private_int);

    let mut public = [0u8; ECC_PUB_KEY_SIZE];
    public[..24].copy_from_slice(&bitvec_to_bytes(&pub_x));
    public[24..].copy_from_slice(&bitvec_to_bytes(&pub_y));
    Some(public)
}

/// Shared secret point (`x ‖ y`, 48 bytes) for our private key and the
/// peer's public key. Returns `None` when the peer point is invalid.
#[must_use]
pub fn shared_secret(
    private: &[u8; ECC_PRV_KEY_SIZE],
    remote_public: &[u8; ECC_PUB_KEY_SIZE],
) -> Option<[u8; ECC_PUB_KEY_SIZE]> {
    let remote_x = bytes_to_bitvec(&remote_public[..24]);
    let remote_y = bytes_to_bitvec(&remote_public[24..]);
    if !gf2point_is_zero(&remote_x, &remote_y) && gf2point_on_curve(&remote_x, &remote_y) {
        let mut private_int = bytes_to_bitvec(private);
        // Copy the peer point to the output, then multiply it by our private
        // (cleared exactly like Gadgetbridge — see `generate_public`).
        let mut out_x = remote_x;
        let mut out_y = remote_y;
        let nbits = bitvec_degree(&BASE_ORDER);
        for bit in (nbits - 1)..BITVEC_NWORDS * 32 {
            bitvec_clr_bit(&mut private_int, bit);
        }
        gf2point_mul(&mut out_x, &mut out_y, &private_int);
        let mut shared = [0u8; ECC_PUB_KEY_SIZE];
        shared[..24].copy_from_slice(&bitvec_to_bytes(&out_x));
        shared[24..].copy_from_slice(&bitvec_to_bytes(&out_y));
        Some(shared)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Captured from the original Gadgetbridge Java implementation (run with
    /// jdk17 against the unmodified `ECDH_B163.java`).
    mod java_vectors {
        pub const PRIV1: [u8; 24] = [
            0xa5, 0xa4, 0xa7, 0xa6, 0xa1, 0xa0, 0xa3, 0xa2, 0xad, 0xac, 0xaf, 0xae, 0xa9, 0xa8,
            0xab, 0xaa, 0xb5, 0xb4, 0xb7, 0xb6, 0xb1, 0xb0, 0xb3, 0xb2,
        ];
        pub const PUB1: [u8; 48] = [
            0x7a, 0x14, 0x77, 0xdf, 0x9a, 0xbf, 0x88, 0x0b, 0xd1, 0x40, 0x96, 0x08, 0x4b, 0x09,
            0x6d, 0xb7, 0xf3, 0xc3, 0xd4, 0x32, 0x06, 0x00, 0x00, 0x00, 0xeb, 0xf9, 0xe2, 0xc8,
            0xac, 0x89, 0xd1, 0x24, 0x68, 0x2b, 0xb4, 0x81, 0x22, 0x0c, 0x54, 0xa2, 0xfd, 0xb0,
            0xf2, 0xe0, 0x03, 0x00, 0x00, 0x00,
        ];
        pub const PRIV2: [u8; 24] = [
            0x59, 0x50, 0x4b, 0x42, 0x45, 0x7c, 0x77, 0x6e, 0x61, 0x18, 0x13, 0x0a, 0x0d, 0x04,
            0x3f, 0x36, 0x29, 0x20, 0xdb, 0xd2, 0xd5, 0xcc, 0xc7, 0xfe,
        ];
        pub const PUB2: [u8; 48] = [
            0x99, 0x25, 0x3d, 0x7b, 0xa6, 0x2a, 0x4e, 0x7e, 0x4a, 0x8f, 0x4d, 0x83, 0x42, 0x25,
            0x55, 0xbb, 0xc0, 0x65, 0x54, 0xd8, 0x02, 0x00, 0x00, 0x00, 0xf3, 0x10, 0x35, 0x05,
            0x7a, 0x45, 0xf5, 0x41, 0xec, 0x97, 0x6d, 0x24, 0x5a, 0xdd, 0x51, 0xaf, 0x7b, 0xc9,
            0xa2, 0x9b, 0x04, 0x00, 0x00, 0x00,
        ];
        pub const SHARED: [u8; 48] = [
            0x60, 0x81, 0xb3, 0x0a, 0xae, 0xd9, 0x7c, 0x19, 0x73, 0x1e, 0x96, 0x62, 0xae, 0xe4,
            0xf4, 0xd0, 0x84, 0x7b, 0x27, 0x3d, 0x05, 0x00, 0x00, 0x00, 0x07, 0x3c, 0xf8, 0x44,
            0x97, 0x09, 0x24, 0xeb, 0x76, 0x33, 0x01, 0x0f, 0x80, 0xff, 0x09, 0xe5, 0xd9, 0xe2,
            0x2f, 0x88, 0x07, 0x00, 0x00, 0x00,
        ];
    }

    #[test]
    fn public_key_matches_java() {
        assert_eq!(
            generate_public(&java_vectors::PRIV1),
            Some(java_vectors::PUB1)
        );
        assert_eq!(
            generate_public(&java_vectors::PRIV2),
            Some(java_vectors::PUB2)
        );
    }

    #[test]
    fn shared_secret_matches_java() {
        assert_eq!(
            shared_secret(&java_vectors::PRIV1, &java_vectors::PUB2),
            Some(java_vectors::SHARED)
        );
        // Symmetry: both sides derive the same secret.
        assert_eq!(
            shared_secret(&java_vectors::PRIV2, &java_vectors::PUB1),
            Some(java_vectors::SHARED)
        );
    }

    #[test]
    fn generated_public_keys_are_on_curve() {
        let mut private = [0u8; 24];
        for (i, b) in private.iter_mut().enumerate() {
            *b = (i as u8) ^ 0xA5;
        }
        let public = generate_public(&private).expect("valid private");
        let x = bytes_to_bitvec(&public[..24]);
        let y = bytes_to_bitvec(&public[24..]);
        assert!(gf2point_on_curve(&x, &y));
    }

    #[test]
    fn rejects_weak_private_and_offcurve_peer() {
        let weak = [0u8; 24];
        assert_eq!(generate_public(&weak), None);
        let private = java_vectors::PRIV1;
        let mut bad_point = java_vectors::PUB2;
        bad_point[0] ^= 0x01;
        assert_eq!(shared_secret(&private, &bad_point), None);
    }
}

#[cfg(test)]
mod dbg3 {
    use super::*;

    #[test]
    fn dbg_mul_consistency() {
        // 2G via mul(exp=2) must equal double(G).
        let two: Bitvec = [2, 0, 0, 0, 0, 0];
        let mut mx = BASE_X;
        let mut my = BASE_Y;
        gf2point_mul(&mut mx, &mut my, &two);
        let mut dx = BASE_X;
        let mut dy = BASE_Y;
        gf2point_double(&mut dx, &mut dy);
        eprintln!("DBG mul==double for 2: {}", mx == dx && my == dy);

        // 5G via mul(exp=5) vs 2*(2G)+G.
        let five: Bitvec = [5, 0, 0, 0, 0, 0];
        let mut fx = BASE_X;
        let mut fy = BASE_Y;
        gf2point_mul(&mut fx, &mut fy, &five);
        let mut px = dx;
        let mut py = dy;
        gf2point_add(&mut px, &mut py, &BASE_X, &BASE_Y);
        gf2point_add(&mut px, &mut py, &dx, &dy);
        eprintln!("DBG mul==add-chain for 5: {}", fx == px && fy == py);

        // On-curve checks.
        eprintln!("DBG 5G on curve: {}", gf2point_on_curve(&fx, &fy));
    }
}
