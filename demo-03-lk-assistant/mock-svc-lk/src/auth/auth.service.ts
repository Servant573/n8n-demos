import { Injectable, UnauthorizedException } from '@nestjs/common';

/**
 * В демо "JWT" — это простая base64-строка с JSON внутри.
 * Формат (base64 from JSON):
 *   { "tenant_id": 1, "user_id": 1, "role": "manager", "exp": ... }
 *
 * В проде — @nestjs/jwt + нормальная верификация подписи svc_gateway.
 * Важно: N8N не верифицирует JWT сам, он доверяет заголовкам от svc_lk.
 */
@Injectable()
export class AuthService {
    parse(token?: string) {
        if (!token) throw new UnauthorizedException('No token');
        const bare = token.replace(/^Bearer\s+/i, '');
        try {
            const decoded = JSON.parse(Buffer.from(bare, 'base64').toString('utf8'));
            if (!decoded.tenant_id) throw new Error('no tenant_id');
            return decoded;
        } catch (e) {
            throw new UnauthorizedException('Invalid token: ' + e.message);
        }
    }
}
