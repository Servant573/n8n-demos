import { Controller, Get, Query, Headers } from '@nestjs/common';
import { ApiOperation, ApiQuery, ApiTags } from '@nestjs/swagger';
import { DbService } from '../db/db.service';
import { AuthService } from '../auth/auth.service';

@ApiTags('invoices')
@Controller('invoices')
export class InvoicesController {
    constructor(
        private readonly db: DbService,
        private readonly auth: AuthService,
    ) {}

    @Get()
    @ApiOperation({ summary: 'Список счетов текущего tenant' })
    @ApiQuery({ name: 'status', required: false, enum: ['paid', 'pending', 'error'] })
    @ApiQuery({ name: 'number', required: false })
    async list(
        @Headers('authorization') token: string,
        @Query('status') status?: string,
        @Query('number') number?: string,
    ) {
        const jwt = this.auth.parse(token);

        const where: string[] = ['tenant_id = $1'];
        const params: any[] = [jwt.tenant_id];

        if (status) {
            where.push(`status = $${params.length + 1}`);
            params.push(status);
        }
        if (number) {
            where.push(`number ILIKE $${params.length + 1}`);
            params.push(`%${number}%`);
        }

        const sql = `
            SELECT id, order_id, number, amount, status, created_at
            FROM lk_assistant.invoices
            WHERE ${where.join(' AND ')}
            ORDER BY created_at DESC
            LIMIT 50
        `;
        const r = await this.db.query(sql, params);
        return {
            tenant_id: jwt.tenant_id,
            count: r.rows.length,
            invoices: r.rows,
        };
    }
}
