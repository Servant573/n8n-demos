import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { OrdersController } from './orders/orders.controller';
import { InvoicesController } from './invoices/invoices.controller';
import { IntegrationController } from './integration/integration.controller';
import { ChatController } from './chat/chat.controller';
import { DbService } from './db/db.service';
import { AuthService } from './auth/auth.service';

@Module({
    imports: [ConfigModule.forRoot({ isGlobal: true })],
    controllers: [
        OrdersController,
        InvoicesController,
        IntegrationController,
        ChatController,
    ],
    providers: [DbService, AuthService],
})
export class AppModule {}
