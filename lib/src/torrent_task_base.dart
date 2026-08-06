export 'task.dart';
export 'utils.dart';
// Диагностика достижимости и проброс порта — часть публичного API: приложение
// показывает Reachability в настройках, а тесты подменяют PortMapper.
export 'nat/reachability.dart';
export 'nat/port_mapper.dart'
    show
        PortMapper,
        PortMapperStatus,
        PortMapMethod,
        PortProtocol,
        MappedPort,
        NatBackend;
