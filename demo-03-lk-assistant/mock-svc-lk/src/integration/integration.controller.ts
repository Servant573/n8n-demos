import { Controller, Get, Headers } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { DbService } from '../db/db.service';
import { AuthService } from '../auth/auth.service';

@ApiTags('integration')
@Controller('integration')
export class IntegrationController {
    constructor(
        private readonly db: DbService,
        private readonly auth: AuthService,
    ) {}

    @Get('status')
    @ApiOperation({ summary: 'Статус обмена данными по tenant (мок-агрегат)' })
    async status(@Headers('authorization') token: string) {
        const jwt = this.auth.parse(token);

        // Используем данные из demo-02 если они есть (та же Postgres), иначе — синтетика
        let recentErrors = 0;
        let lastSuccessful: string | null = null;
        try {
            const r = await this.db.query(
                `SELECT
                    COUNT(*) FILTER (WHERE ai_category IS NOT NULL AND processed_at > NOW() - INTERVAL '24 hours') AS errors_24h,
                    MAX(processed_at) AS last_error
                 FROM dlq_handler.dlq_events
                 WHERE counterparty_id = $1`,
                [jwt.tenant_id],
            );
            recentErrors = parseInt(r.rows[0]?.errors_24h || 0, 10);
        } catch (e) {
            // таблицы может не быть если demo-02 не развёрнуто
        }

        return {
            tenant_id: jwt.tenant_id,
            status: recentErrors === 0 ? 'healthy' : recentErrors < 3 ? 'degraded' : 'unhealthy',
            errors_last_24h: recentErrors,
            last_sync_at: new Date(Date.now() - 1000 * 60 * 15).toISOString(),
            queue_backlog: 0,
            message: recentErrors === 0
                ? 'Обмен данными работает штатно.'
                : `Зафиксировано ${recentErrors} ошибок за сутки. Рекомендуется проверить логи.`,
        };
    }
}
