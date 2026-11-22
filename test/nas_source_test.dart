import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tingshu/models/ting.dart';
import 'package:tingshu/services/nas/nas_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('播放源标识', () {
    test('NAS 存进本地的 id 稳定，老数据也不会被当成夸克', () {
      expect(TingSource.nas.id, 'nas');
      expect(TingSourceLabel.parse('nas'), TingSource.nas);
      expect(TingSourceLabel.parse('quark'), TingSource.quark);
      expect(TingSourceLabel.parse(null), TingSource.bili);
      expect(TingSourceLabel.parse('随便什么'), TingSource.bili);
    });
  });

  group('NAS 播放地址', () {
    test('拼出 WebDAV 文件 URL，并带 Basic 鉴权头', () async {
      SharedPreferences.setMockInitialValues({});
      await NasSource.instance.load();
      await NasSource.instance.saveConfig(
        url: 'http://nas.local:5005/dav/',
        user: 'book',
        pass: 'test-pass',
        root: '/评书',
        rootName: '评书',
      );

      final book = TingBook(
        id: '/单田芳/水浒传',
        source: TingSource.nas,
        title: '水浒传',
        chapters: const [
          TingChapter(index: 0, title: '武松打虎', key: '/评书/单田芳/水浒传/001 回.mp3'),
        ],
      );

      final audio = await NasSource.instance.resolve(book, book.chapters.first);

      // 末尾斜杠要被吃掉，路径要按段编码（中文 + 空格）
      expect(audio.url.startsWith('http://nas.local:5005/dav/'), isTrue);
      expect(audio.url.contains('%E8%AF%84%E4%B9%A6'), isTrue);
      expect(audio.url.contains('%20'), isTrue);
      expect(audio.url.endsWith('.mp3'), isTrue);
      expect(audio.headers['Authorization'], startsWith('Basic '));
    });

    test('没配置时明确报错，不让界面卡住', () async {
      SharedPreferences.setMockInitialValues({});
      await NasSource.instance.load();
      expect(NasSource.instance.configured, isFalse);
      expect(
        () => NasSource.instance.listBooks(),
        throwsA(isA<Exception>()),
      );
    });
  });
}
