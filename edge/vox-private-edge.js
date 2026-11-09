// CloudFront Function (viewer-request, cloudfront-js-2.0) for the private area of Vox (/privado).
//
//   /privado, /privado/            portal page, behind HTTP Basic Auth
//   /privado/<guid>/...            the private site; the guid itself is the credential
//
// Everything that decides access lives in the associated KeyValueStore, never in this code:
//   pw          sha256 (hex) of the full "Authorization" header value ("Basic base64(user:password)")
//   t:<guid>    presence authorizes the site under that guid (delete the key to revoke it)
//
// Anything else answers 404, never 403. The URI rewrite mirrors vox-url-rewrite (Hugo pretty URLs
// against an S3 REST origin).
import cf from 'cloudfront';
import crypto from 'crypto';

const kvs = cf.kvs();

const SITE = /^\/privado\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(\/.*)?$/;

function notFound() {
  return {
    statusCode: 404,
    statusDescription: 'Not Found',
    headers: { 'cache-control': { value: 'no-store' } },
  };
}

function unauthorized() {
  return {
    statusCode: 401,
    statusDescription: 'Unauthorized',
    headers: {
      'www-authenticate': { value: 'Basic realm="Vox privado", charset="UTF-8"' },
      'cache-control': { value: 'no-store' },
    },
  };
}

function same(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function rewrite(uri) {
  if (uri.endsWith('.html') && !uri.endsWith('/index.html')) {
    uri = uri.slice(0, -5) + '/index.html';
  }
  if (uri.endsWith('/')) {
    uri += 'index.html';
  } else if (!uri.split('/').pop().includes('.')) {
    uri += '/index.html';
  }
  return uri;
}

async function handler(event) {
  const request = event.request;
  const uri = request.uri;

  if (uri === '/privado' || uri === '/privado/' || uri === '/privado/index.html') {
    const header = request.headers.authorization;
    if (!header) return unauthorized();

    let expected;
    try {
      expected = await kvs.get('pw');
    } catch (e) {
      return unauthorized();
    }

    const hash = crypto.createHash('sha256').update(header.value).digest('hex');
    if (!same(hash, expected)) return unauthorized();

    request.uri = '/privado/index.html';
    return request;
  }

  const m = SITE.exec(uri);
  if (!m) return notFound();

  let allowed = false;
  try {
    allowed = await kvs.exists('t:' + m[1]);
  } catch (e) {
    allowed = false;
  }
  if (!allowed) return notFound();

  if (m[2] === undefined) {
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: { location: { value: uri + '/' } },
    };
  }

  request.uri = rewrite(uri);
  return request;
}
