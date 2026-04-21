import { Injectable, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { Pool } from 'pg';

@Injectable()
export class DbService implements OnModuleInit, OnModuleDestroy {
    private pool: Pool;

    onModuleInit() {
        this.pool = new Pool({
            host: process.env.DB_HOST || 'localhost',
            port: parseInt(process.env.DB_PORT || '5432', 10),
            database: process.env.DB_NAME || 'demo',
            user: process.env.DB_USER || 'demo',
            password: process.env.DB_PASS || 'demo_secret',
            max: 10,
        });
    }

    async onModuleDestroy() {
        await this.pool?.end();
    }

    query<T = any>(sql: string, params: any[] = []): Promise<{ rows: T[] }> {
        return this.pool.query(sql, params);
    }
}
