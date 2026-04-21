import { Controller, Get, Query, Headers } from '@nestjs/common';
import { ApiOperation, ApiQuery, ApiTags } from '@nestjs/swagger';
import { DbService } from '../db/db.service';
import { AuthService } from '../auth/auth.service';

@ApiTags('orders')
@Controller('orders')
export class OrdersController {
    constructor(
        private readonly db: DbService,
        private readonly auth: AuthService,
    ) {}

    @Get()
    @ApiOperation({ summary: 'Список заказов текущего tenant' })
    @ApiQuery({ name: 'status', required: false, enum: ['new', 'in_progress', 'in_transit', 'delivered', 'error'] })
    @ApiQuery({ name: 'number', required: false })
    @ApiQuery({ name: 'limit', required: false })
    async list(
        @Headers('authorization') token: string,
        @Query('status') status?: string,
        @Query('number') number?: string,
        @Query('limit') limit?: string,
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

        const lim = Math.min(parseInt(limit || '20', 10), 100);

        const sql = `
            SELECT id, number, counterparty, amount, status, delivery_date, created_at
            FROM lk_assistant.orders
            WHERE ${where.join(' AND ')}
            ORDER BY created_at DESC
            LIMIT ${lim}
        `;
        const r = await this.db.query(sql, params);
        return {
            tenant_id: jwt.tenant_id,
            count: r.rows.length,
            orders: r.rows,
        };
    }
}
