'use strict';
const { keys, sameOrigin, signatureOk } = require('./_razorpay');

// POST /api/verify  { razorpay_order_id, razorpay_payment_id, razorpay_signature }  ->  { ok: true }
// The browser callback is not proof of payment; the signature is. Nothing here
// grants anything, it only tells the page whether to show "thank you".
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({ error: 'method_not_allowed' }); }
  if (!sameOrigin(req)) return res.status(403).json({ error: 'forbidden' });

  const k = keys();
  if (!k) return res.status(503).json({ error: 'not_configured' });

  let b = req.body;
  if (typeof b === 'string') { try { b = JSON.parse(b); } catch (_) { b = null; } }
  const o = b && b.razorpay_order_id, p = b && b.razorpay_payment_id, s = b && b.razorpay_signature;
  if (typeof o !== 'string' || typeof p !== 'string' || !/^order_\w{6,40}$/.test(o) || !/^pay_\w{6,40}$/.test(p)) {
    return res.status(400).json({ error: 'bad_request' });
  }
  if (!signatureOk(o, p, s, k.secret)) return res.status(400).json({ ok: false, error: 'bad_signature' });
  return res.status(200).json({ ok: true });
};
