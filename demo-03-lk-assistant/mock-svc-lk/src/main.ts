import { NestFactory } from '@nestjs/core';
import { SwaggerModule, DocumentBuilder } from '@nestjs/swagger';
import { AppModule } from './app.module';

async function bootstrap() {
    const app = await NestFactory.create(AppModule);
    app.enableCors({
        origin: true,
        credentials: true,
    });

    const cfg = new DocumentBuilder()
        .setTitle('mock-svc-lk')
        .setDescription('Упрощённый mock сервиса svc_lk для demo-03')
        .setVersion('1.0')
        .build();
    const document = SwaggerModule.createDocument(app, cfg);
    SwaggerModule.setup('api/docs', app, document);

    const port = process.env.PORT || 3100;
    await app.listen(port);
    console.log(`mock-svc-lk listening on http://localhost:${port}`);
    console.log(`Swagger docs:      http://localhost:${port}/api/docs`);
}
bootstrap();
