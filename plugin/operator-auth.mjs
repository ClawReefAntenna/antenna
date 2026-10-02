// Local operator credentials only. Never exported as Antenna peer authority.
export function operatorAuth(host, forbidden = []) {
 const auth = host.gateway?.auth ?? {};
 const mode = auth.mode ?? (auth.token !== undefined ? 'token' : 'password');
 if (!['token', 'password'].includes(mode)) throw Error('Token or password gateway authentication required');
 const value = auth[mode];
 if (typeof value !== 'string' || !value.trim()) throw Error('Resolved local gateway credential required');
 if (forbidden.includes(value)) throw Error('Antenna bearer must differ from resolved operator credential');
 return {[mode]: value};
}
