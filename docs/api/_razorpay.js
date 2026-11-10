'use strict';
// Shared by the payment functions. Server-side only: the key secret never
// reaches the browser, and the amount is fixed here, never taken from the client.
const crypto = require('node:crypto');

// One-time support payment. Razorpay amounts are in the smallest unit (paise).
// 44900 paise = Rs 449, roughly USD 5. Change it here and nowhere else.
const AMOUNT_PAISE = 44900;
const CURRENCY = 'INR';

function keys() {
  const id = process.env.RAZORPAY_KEY_ID, secret = process.env.RAZORPAY_KEY_SECRET;
  if (!id || !secret) return null;
  return { id, secret };
}

function apiBase() {
  // Overridable so the flow can be tested against a mock without real keys.
  return process.env.RAZORPAY_API_BASE || 'https://api.razorpay.com';
}

function sameOrigin(req) {
  const origin = req.headers.origin;
  if (!origin) return true;                       // same-origin form posts omit it
  try {
    const host = new URL(origin).host;
    return host === req.headers.host;
  } catch (_) { return false; }
}

function signatureOk(orderId, paymentId, signature, secret) {
  if (typeof signature !== 'string' || !/^[0-9a-f]{64}$/.test(signature)) return false;
  const expected = crypto.createHmac('sha256', secret).update(orderId + '|' + paymentId).digest('hex');
  return crypto.timingSafeEqual(Buffer.from(expected, 'hex'), Buffer.from(signature, 'hex'));
}

module.exports = { AMOUNT_PAISE, CURRENCY, keys, apiBase, sameOrigin, signatureOk };
