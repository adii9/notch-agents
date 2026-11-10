'use strict';
const { AMOUNT_PAISE, CURRENCY, keys, apiBase, sameOrigin } = require('./_razorpay');

// POST /api/create-order  ->  { keyId, orderId, amount, currency }
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({ error: 'method_not_allowed' }); }
  if (!sameOrigin(req)) return res.status(403).json({ error: 'forbidden' });

  const k = keys();
  if (!k) return res.status(503).json({ error: 'not_configured' });

  try {
    const r = await fetch(apiBase() + '/v1/orders', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Basic ' + Buffer.from(k.id + ':' + k.secret).toString('base64')
      },
      body: JSON.stringify({
        amount: AMOUNT_PAISE,
        currency: CURRENCY,
        receipt: 'na_' + Date.now().toString(36),
        notes: { source: 'notch-agents-site', purpose: 'support' }
      }),
      signal: AbortSignal.timeout(8000)
    });
    const order = await r.json().catch(() => ({}));
    if (!r.ok || !order.id) {
      console.error('razorpay order failed', r.status, order && order.error && order.error.code);
      return res.status(502).json({ error: 'order_failed' });
    }
    return res.status(200).json({ keyId: k.id, orderId: order.id, amount: order.amount, currency: order.currency });
  } catch (e) {
    console.error('razorpay order error', e && e.name);
    return res.status(502).json({ error: 'order_failed' });
  }
};
