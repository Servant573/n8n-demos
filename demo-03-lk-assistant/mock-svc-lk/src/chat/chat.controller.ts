import { Body, Controller, Headers, Post } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import axios from 'axios';
import { AuthService } from '../auth/auth.service';
import { DbService } from '../db/db.service';

interface ChatRequest {
    message: string;
    session_id?: string;
    ai_tier?: 'basic' | 'premium';
}

@ApiTags('chat')
@Controller('chat')
export class ChatController {
    private readonly n8nUrl =
        process.env.N8N_ASSISTANT_WEBHOOK ||
        'http://localhost:5678/webhook/lk-assistant';

    constructor(
        private readonly auth: AuthService,
        private readonly db: DbService,
    ) {}

    @Post()
    @ApiOperation({ summary: 'Отправить сообщение AI-ассистенту' })
    async chat(
        @Headers('authorization') token: string,
        @Body() body: ChatRequest,
    ) {
        const jwt = this.auth.parse(token);

        // Подгружаем ai_tier из БД, если клиент передал не то (безопасность: нельзя
        // позволять клиенту самому решать, на каком тарифе он живёт)
        const tenantResult = await this.db.query(
            'SELECT ai_tier FROM lk_assistant.tenants WHERE id = $1',
            [jwt.tenant_id],
        );
        const authoritativeTier = tenantResult.rows[0]?.ai_tier || 'basic';

        // Формируем payload для N8N webhook
        const payload = {
            tenant_id: jwt.tenant_id,
            user_id: jwt.user_id,
            role: jwt.role,
            session_id: body.session_id,
            message: body.message,
            ai_tier: authoritativeTier,
            // Токен передаём обратно, чтобы tool'ы N8N могли дёрнуть нас обратно
            // от имени того же пользователя.
            auth_token: token.replace(/^Bearer\s+/i, ''),
        };

        try {
            const { data } = await axios.post(this.n8nUrl, payload, {
                timeout: 60000,
                headers: { 'content-type': 'application/json' },
            });
            return data;
        } catch (err) {
            // Если N8N не поднят — возвращаем fallback-ответ, чтобы UI не падал
            console.error('N8N webhook failed:', err.message);
            return {
                answer: 'AI-ассистент временно недоступен. Попробуйте позже или обратитесь в поддержку.',
                tools_used: [],
                session_id: body.session_id,
                _fallback: true,
                _error: err.message,
            };
        }
    }
}
